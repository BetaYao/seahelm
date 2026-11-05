//! Daily model review and card-backed habit proposals. All grants stay in
//! the core; a review is evidence, never permission to act.
use super::engine::{iso8601, Entry};
use super::{
    budget, habits, observations, policy, FirstMate, RpcError, RpcResult, APPROVE, REJECT,
};
use seahelm_core_registry::cards::CardKind;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

pub(super) struct PendingHabit {
    pub key: String,
    pub repo: Option<String>,
    pub habit: habits::Habit,
}

const DAY: f64 = 86400.0;
const REVIEW_BYTES: usize = 24000;

pub(super) fn grouped(records: &[observations::Record], since: f64) -> Vec<Value> {
    let cutoff = iso8601(since);
    let mut groups: BTreeMap<String, (usize, BTreeSet<String>, BTreeSet<String>)> = BTreeMap::new();
    for r in records.iter().filter(|r| r.at > cutoff) {
        let signature = json!({"kind":r.kind,"repo":r.repo,"by":r.by,"facts":r.fields.get("facts"),"habit":r.fields.get("habit"),"option":r.fields.get("option")}).to_string();
        let g = groups.entry(signature).or_default();
        g.0 += 1;
        g.1.insert(r.at.chars().take(10).collect());
        if !r.worktree.is_empty() {
            g.2.insert(r.worktree.clone());
        }
    }
    groups.into_iter().map(|(signature,(count,days,worktrees))| json!({"signature":serde_json::from_str::<Value>(&signature).unwrap(),"count":count,"days":days,"distinct_worktrees":worktrees.len()})).collect()
}

fn review_due(enabled_at: f64, last_review: f64, last_seen: f64, now: f64) -> bool {
    enabled_at > 0.0 && now - enabled_at.max(last_review) >= DAY && now - last_seen >= 1800.0
}

impl FirstMate {
    pub(super) fn propose_habit(&mut self, mut value: Value, now: f64) -> RpcResult {
        if !self.running || self.config.paused {
            return Err(super::refused("First Mate is not running"));
        }
        if value.to_string().len() > 12000 {
            return Err(RpcError::invalid_params("habit too large"));
        }
        let repo = value
            .get("repo")
            .and_then(Value::as_str)
            .map(str::to_string);
        let key = repo
            .as_deref()
            .map(habits::repo_key)
            .unwrap_or_else(|| habits::GLOBAL.into());
        // Proposals never import model-supplied evidence or grants.
        for key in ["evidence", "approved", "sources", "observed", "origin"] {
            if let Some(o) = value.as_object_mut() {
                o.remove(key);
            }
        }
        value["level"] = json!("ask");
        value["origin"] = json!("learned");
        value["observed"] = json!(Self::today(now));
        let book = habits::Book::parse(
            &key,
            &serde_yaml::to_string(&vec![value]).unwrap_or_default(),
            &Default::default(),
        );
        if let Some((_, why)) = book.invalid.first() {
            return Err(RpcError::invalid_params(why));
        }
        let Some(mut habit) = book.habits.into_iter().next() else {
            return Err(RpcError::invalid_params("habit required"));
        };
        habit.level = habits::HabitLevel::Ask;
        if self
            .habit_proposals
            .values()
            .any(|p| p.key == key && p.habit.id == habit.id)
        {
            return Err(RpcError::invalid_params(
                "a proposal for this habit is already pending",
            ));
        }
        let id = self.mint("habit.proposal");
        let text = super::lang::Text::new(
            format!(
                "First Mate proposes habit {}: {}. Ask before {}?",
                habit.id,
                habits::describe_when(&habit.when),
                format!("{:?}", habit.act)
            ),
            format!(
                "First Mate 提议习惯 {}：{}。执行 {} 前先询问你？",
                habit.id,
                habits::describe_when(&habit.when),
                format!("{:?}", habit.act)
            ),
        );
        self.put_card(
            CardKind::Approval,
            &id,
            text.get(self.config.language).into(),
            vec![APPROVE.into(), REJECT.into()],
            if self.user_spoke {
                budget::Class::Answering
            } else {
                budget::Class::Proactive
            },
            now,
        );
        self.log(Entry::new(
            now,
            "approval",
            format!("proposed habit {}", habit.id),
        ));
        self.habit_proposals
            .insert(id.clone(), PendingHabit { key, repo, habit });
        Ok(json!({"card":id,"queued":"habit"}))
    }

    pub(super) fn review_if_due(&mut self, now: f64) {
        if self.budget.review_enabled_at <= 0.0 {
            self.budget.review_enabled_at = now;
            self.save_budget();
            return;
        }
        let since = self.budget.last_review.max(self.budget.review_enabled_at);
        let presence = self.core.presence();
        if !review_due(
            self.budget.review_enabled_at,
            self.budget.last_review,
            presence.profile.last_seen,
            now,
        ) {
            return;
        }
        let records = observations::read_records(&self.dir.join(observations::FILE_NAME));
        // Add only complete JSON entries while keeping a hard UTF-8 byte cap.
        let mut sections = json!({"observations":[],"conversation":[],"project_prompts":[]});
        let mut add = |section: &str, value: Value| {
            sections[section].as_array_mut().unwrap().push(value);
            if sections.to_string().len() > REVIEW_BYTES - 200 {
                sections[section].as_array_mut().unwrap().pop();
            }
        };
        for group in grouped(&records, since).into_iter().take(30) {
            add("observations", group);
        }
        for m in self
            .core
            .messages_of(policy::SESSION)
            .into_iter()
            .filter(|m| m.ts > since)
            .rev()
            .take(10)
        {
            if matches!(
                m.kind,
                seahelm_core_messages::Kind::User | seahelm_core_messages::Kind::Assistant
            ) {
                if m.text.as_deref().is_some_and(|t| t.starts_with("[seahelm")) {
                    continue;
                }
                add(
                    "conversation",
                    json!({"kind":m.kind.as_str(),"text":m.text.unwrap_or_default().chars().take(500).collect::<String>()}),
                );
            }
        }
        let mut per_project: BTreeMap<String, usize> = BTreeMap::new();
        for (at, project, text) in presence
            .profile
            .prompts
            .iter()
            .rev()
            .filter(|(at, _, _)| *at > since)
        {
            let count = per_project.entry(project.clone()).or_default();
            if *count < 5 {
                add(
                    "project_prompts",
                    json!({"at":at,"project":project,"text":text.chars().take(300).collect::<String>()}),
                );
                *count += 1;
            }
        }
        self.tell(&format!("[seahelm event] learn.review\n{sections}"));
        self.budget.last_review = now;
        self.save_budget();
        self.log(Entry::new(now, "delivered", "learn.review"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn counts_days_and_distinct_worktrees_without_model_counting() {
        let mut a = observations::Record::new("worktree.removed", observations::By::User);
        a.at = iso8601(100000.0);
        a.worktree = "a".into();
        let mut b = a.clone();
        b.at = iso8601(200000.0);
        b.worktree = "b".into();
        let groups = grouped(&[a.clone(), a, b], 0.0);
        assert_eq!(groups[0]["count"], 3);
        assert_eq!(groups[0]["distinct_worktrees"], 2);
        assert_eq!(groups[0]["days"].as_array().unwrap().len(), 2);
    }
    #[test]
    fn a_judgement_proposal_is_only_saved_after_the_localized_yes() {
        let tmp = tempfile::tempdir().unwrap();
        let core = crate::core::Core::for_test(tmp.path());
        let dir = tmp.path().join("first-mate");
        std::fs::create_dir_all(&dir).unwrap();
        let (tx, _rx) = std::sync::mpsc::channel();
        let mut fm = FirstMate::new(core, tx, dir.clone(), dir.join("habits"));
        fm.running = true;
        fm.config.language = super::super::lang::Lang::Zh;
        fm.user_spoke = true;
        let result = fm.propose_habit(json!({"id":"docs-only","when":"docs-only PRs","do":"delete_worktree","level":"auto"}),100000.0).unwrap();
        assert!(fm
            .habits
            .load(habits::GLOBAL, "2026-11-05")
            .get("docs-only")
            .is_none());
        fm.config.language = super::super::lang::Lang::En;
        fm.answered(
            result["card"].as_str().unwrap(),
            Some("批准"),
            None,
            100001.0,
        );
        let book = fm.habits.load(habits::GLOBAL, "2026-11-05");
        let h = book.get("docs-only").unwrap();
        assert_eq!(book.level(h), habits::HabitLevel::Ask);
        assert!(!h.when.matches(&Default::default()));
        assert!(h.when.admits_risk());
        assert_eq!(h.when.1.as_deref(), Some("docs-only PRs"));
    }
    #[test]
    fn measured_conditions_reject_unknown_facts_and_prose_round_trips() {
        assert!(serde_yaml::from_str::<habits::When>("{imaginary: 0}").is_err());
        let when: habits::When = serde_yaml::from_str("leave docs PRs alone").unwrap();
        let encoded = serde_yaml::to_string(&when).unwrap();
        assert_eq!(
            serde_yaml::from_str::<habits::When>(&encoded).unwrap(),
            when
        );
    }

    #[test]
    fn review_waits_a_full_day_and_for_idle_presence() {
        assert!(!review_due(100.0, 0.0, 100.0, 86499.0));
        assert!(!review_due(100.0, 0.0, 86499.0, 86500.0));
        assert!(review_due(100.0, 0.0, 80000.0, 86500.0));
        assert!(!review_due(100.0, 86500.0, 80000.0, 86501.0));
        assert!(!review_due(0.0, 0.0, 0.0, 100000.0));
    }
}
