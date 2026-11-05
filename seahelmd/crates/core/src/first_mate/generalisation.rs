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

fn age_bucket(value: Option<u64>) -> &'static str {
    match value {
        Some(0) => "0",
        Some(1..=3) => "1-3",
        Some(4..=14) => "4-14",
        Some(_) => "15+",
        None => "unknown",
    }
}

pub(super) fn grouped(records: &[observations::Record], since: f64) -> Vec<Value> {
    let cutoff = iso8601(since);
    let mut groups: BTreeMap<
        String,
        (usize, BTreeSet<String>, BTreeSet<String>, BTreeSet<String>),
    > = BTreeMap::new();
    for r in records
        .iter()
        .filter(|r| r.at > cutoff && r.kind.starts_with("worktree."))
    {
        let facts = r.fields.get("facts").cloned().unwrap_or(Value::Null);
        let measured = serde_json::from_value::<super::facts::Facts>(facts.clone()).ok();
        let signature = json!({"kind":r.kind,"by":r.by,"pr":facts.get("pr"),
            "at_risk":measured.as_ref().and_then(habits::at_risk),
            "nothing_to_lose":measured.as_ref().map(habits::nothing_to_lose),
            "days_since_merge":age_bucket(facts.get("days_since_merge").and_then(Value::as_u64)),
            "idle_days":age_bucket(facts.get("idle_days").and_then(Value::as_u64)),
            "busy_panes":facts.get("busy_panes").and_then(Value::as_u64).map(|n| n > 0)})
        .to_string();
        let g = groups.entry(signature).or_default();
        g.0 += 1;
        g.1.insert(r.at.chars().take(10).collect());
        if !r.worktree.is_empty() {
            g.2.insert(r.worktree.clone());
        }
        if g.3.len() < 5 {
            g.3.insert(
                format!("{}: {}", r.repo, r.branch)
                    .chars()
                    .take(200)
                    .collect(),
            );
        }
    }
    let mut result: Vec<Value> = groups.into_iter().map(|(signature,(count,days,worktrees,examples))|
        json!({"signature":serde_json::from_str::<Value>(&signature).unwrap(),"count":count,"days":days,"distinct_days":days.len(),"distinct_worktrees":worktrees.len(),"examples":examples})).collect();
    result.sort_by(|a, b| {
        b["count"]
            .as_u64()
            .cmp(&a["count"].as_u64())
            .then_with(|| a["signature"].to_string().cmp(&b["signature"].to_string()))
    });
    result
}

fn card_outcomes(records: &[observations::Record], since: f64) -> Vec<Value> {
    let cutoff = iso8601(since);
    let mut counts: BTreeMap<String, [u64; 4]> = BTreeMap::new();
    for r in records.iter().filter(|r| r.at > cutoff) {
        let Some(habits) = r.fields.get("habit").and_then(Value::as_str) else {
            continue;
        };
        let outcome = if r.kind == observations::kind::CARD_EXPIRED {
            2
        } else if r.kind == observations::kind::CARD_ANSWERED {
            match r
                .fields
                .get("option")
                .and_then(Value::as_str)
                .map(super::lang::option_key)
                .as_deref()
            {
                None => 3,
                Some("approve" | "delete" | "delete_all") => 0,
                Some(key) if key.starts_with("yes:") || key.starts_with("confirm:") => 0,
                _ => 1,
            }
        } else {
            continue;
        };
        let distinct: BTreeSet<_> = habits.split(',').filter(|h| !h.is_empty()).collect();
        for habit in distinct {
            counts.entry(habit.into()).or_default()[outcome] += 1;
        }
    }
    counts.into_iter().map(|(habit,c)|json!({"habit":habit,"approved":c[0],"rejected":c[1],"ignored":c[2],"dismissed":c[3]})).collect()
}

fn review_content(
    records: &[observations::Record],
    messages: Vec<seahelm_core_messages::Message>,
    prompts: &[(f64, String, String)],
    since: f64,
) -> String {
    let mut sections =
        json!({"observations":[],"card_outcomes":[],"conversation":[],"project_prompts":[]});
    let mut add = |section: &str, value: Value| {
        sections[section].as_array_mut().unwrap().push(value);
        let section_cap = match section {
            "observations" => 10000,
            "card_outcomes" => 5000,
            "conversation" => 5000,
            _ => 3000,
        };
        if sections[section].to_string().len() > section_cap
            || sections.to_string().len() > REVIEW_BYTES - 100
        {
            sections[section].as_array_mut().unwrap().pop();
        }
    };
    // Reserve space for conversation and outcomes before the potentially large groups.
    let mut conversation: Vec<_> = messages
        .into_iter()
        .filter(|m| {
            m.ts > since
                && matches!(
                    m.kind,
                    seahelm_core_messages::Kind::User | seahelm_core_messages::Kind::Assistant
                )
                && !m
                    .text
                    .as_deref()
                    .unwrap_or_default()
                    .starts_with("[seahelm")
        })
        .rev()
        .take(10)
        .collect();
    conversation.reverse();
    for m in conversation {
        add(
            "conversation",
            json!({"kind":m.kind.as_str(),"text":m.text.unwrap_or_default().chars().take(150).collect::<String>()}),
        );
    }
    for outcome in card_outcomes(records, since) {
        add("card_outcomes", outcome);
    }
    let mut per_project: BTreeMap<&str, usize> = BTreeMap::new();
    for (at, project, text) in prompts.iter().rev().filter(|(at, _, _)| *at > since) {
        let n = per_project.entry(project).or_default();
        if *n < 5 {
            add(
                "project_prompts",
                json!({"at":at,"project":project,"text":text.chars().take(300).collect::<String>()}),
            );
            *n += 1;
        }
    }
    for group in grouped(records, since).into_iter().take(30) {
        add("observations", group);
    }
    format!("[seahelm event] learn.review\n{sections}")
}

fn review_due(enabled_at: f64, last_review: f64, last_seen: f64, now: f64) -> bool {
    enabled_at > 0.0 && now - enabled_at.max(last_review) >= DAY && now - last_seen >= 1800.0
}

impl FirstMate {
    pub(super) fn propose_habit(&mut self, mut value: Value, now: f64) -> RpcResult {
        if !self.running || self.config.paused {
            return Err(super::refused("First Mate is not running"));
        }
        if !value.is_object() {
            return Err(RpcError::invalid_params("habit must be an object"));
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
        if value
            .get("when")
            .is_some_and(|when| when.is_string() || when.get("judgement").is_some())
            && value.get("judgement").and_then(Value::as_bool) != Some(true)
        {
            return Err(RpcError::invalid_params(
                "prose when requires judgement: true",
            ));
        }
        if value.get("when").is_some_and(Value::is_string) {
            if value.get("judgement").and_then(Value::as_bool) != Some(true) {
                return Err(RpcError::invalid_params(
                    "prose when requires judgement: true",
                ));
            }
            value["when"] = json!({"judgement": value["when"]});
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
        if self
            .habits
            .load(&key, &Self::today(now))
            .get(&habit.id)
            .is_some()
        {
            return Err(RpcError::invalid_params(
                "habit id already exists; proposals cannot replace it",
            ));
        }
        let id = self.mint("habit.proposal");
        let text = super::lang::Text::new(
            format!(
                "First Mate proposes habit {}: {}. Ask before {}?",
                habit.id,
                habits::describe_when(&habit.when),
                super::lang::habit_action(habit.act, super::lang::Lang::En)
            ),
            format!(
                "First Mate 提议习惯 {}：{}。执行 {} 前先询问你？",
                habit.id,
                habits::describe_when(&habit.when),
                super::lang::habit_action(habit.act, super::lang::Lang::Zh)
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
        let Some(text) = self.review_text_if_due(now) else {
            return;
        };
        self.tell(&text);
        self.budget.last_review = now;
        self.save_budget();
        self.log(Entry::new(now, "delivered", "learn.review"));
    }
    fn review_text_if_due(&self, now: f64) -> Option<String> {
        if !review_due(
            self.budget.review_enabled_at,
            self.budget.last_review,
            self.core.presence_last_seen(),
            now,
        ) {
            return None;
        }
        let since = self.budget.last_review.max(self.budget.review_enabled_at);
        let presence = self.core.presence();
        let records = observations::read_records(&self.dir.join(observations::FILE_NAME));
        Some(review_content(
            &records,
            self.core.messages_of(policy::SESSION),
            &presence.profile.prompts,
            since,
        ))
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
        let result = fm.propose_habit(json!({"id":"docs-only","when":"docs-only PRs","judgement":true,"do":"delete_worktree","level":"auto"}),100000.0).unwrap();
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
        let when: habits::When = serde_yaml::from_str("{judgement: leave docs PRs alone}").unwrap();
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
    fn fixture(
        tmp: &std::path::Path,
    ) -> (
        std::sync::Arc<crate::core::Core>,
        FirstMate,
        std::sync::mpsc::Receiver<super::super::Msg>,
    ) {
        let core = crate::core::Core::for_test(tmp);
        let dir = tmp.join("first-mate");
        std::fs::create_dir_all(&dir).unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        core.set_test_first_mate(super::super::Handle(tx.clone()));
        let mut fm = FirstMate::new(core.clone(), tx, dir.clone(), dir.join("habits"));
        fm.running = true;
        fm.user_spoke = true;
        core.ensure_first_mate_pane(&dir.to_string_lossy());
        (core, fm, rx)
    }
    fn rpc(core: &std::sync::Arc<crate::core::Core>, method: &str, params: Value) -> RpcResult {
        use crate::rpc::Dispatch;
        match core.clone().call(method, params) {
            crate::rpc::Reply::Value(result) => result,
            _ => panic!("unexpected stream"),
        }
    }
    #[test]
    fn coarse_groups_merge_ages_and_rank_by_count() {
        let records: Vec<_> = (0..4)
            .map(|i| {
                let facts = super::super::facts::Facts {
                    pr: Some("merged".into()),
                    unpushed: Some(0),
                    idle_days: Some(if i == 3 { 20 } else { i + 1 }),
                    days_since_merge: Some(if i == 3 { 20 } else { i + 1 }),
                    last_commit_at: Some(i as f64),
                    ..Default::default()
                };
                let mut r = observations::Record::new("worktree.removed", observations::By::User)
                    .with("facts", json!(facts));
                r.at = iso8601(100000.0 + i as f64 * 86400.0);
                r.worktree = format!("/wt/{i}");
                r.branch = format!("feat/{i}");
                r
            })
            .collect();
        let groups = grouped(&records, 0.0);
        assert_eq!(groups.len(), 2);
        assert_eq!(groups[0]["count"], 3);
        assert_eq!(groups[0]["distinct_days"], 3);
        assert_eq!(groups[0]["examples"].as_array().unwrap().len(), 3);
    }
    #[test]
    fn review_content_counts_outcomes_filters_before_taking_and_caps_utf8() {
        use seahelm_core_messages::{Kind, Message};
        let records: Vec<_> = [Some("Approve"), Some("reject"), None]
            .into_iter()
            .map(|option| {
                let mut r = observations::Record::new(
                    observations::kind::CARD_ANSWERED,
                    observations::By::User,
                )
                .with("habit", json!("global/h"))
                .with("option", json!(option));
                r.at = iso8601(100000.0);
                r
            })
            .chain(std::iter::once({
                let mut r = observations::Record::new(
                    observations::kind::CARD_EXPIRED,
                    observations::By::User,
                )
                .with("habit", json!("global/h"));
                r.at = iso8601(100000.0);
                r
            }))
            .collect();
        let messages: Vec<_> = (0..20)
            .flat_map(|i| {
                [
                    Message::new("m", "m", Kind::User, 100000.0 + i as f64)
                        .with_text(i.to_string()),
                    Message::new("m", "m", Kind::Tool, 100000.0 + i as f64).with_text("tool"),
                ]
            })
            .collect();
        let prompts: Vec<_> = (0..200)
            .map(|i| (100000.0, format!("repo/{i}"), "中文\\\"".repeat(10000)))
            .collect();
        let text = review_content(&records, messages, &prompts, 0.0);
        assert!(text.len() <= REVIEW_BYTES);
        let v: Value = serde_json::from_str(text.split_once('\n').unwrap().1).unwrap();
        assert_eq!(v["conversation"].as_array().unwrap().len(), 10);
        assert_eq!(v["conversation"][0]["text"], "10");
        assert_eq!(v["conversation"][9]["text"], "19");
        assert_eq!(
            v["card_outcomes"][0],
            json!({"habit":"global/h","approved":1,"rejected":1,"ignored":1,"dismissed":1})
        );
        assert!(!v["project_prompts"].as_array().unwrap().is_empty());
    }
    #[test]
    fn named_habit_gate_denies_unknown_and_caps_auto_with_visible_name() {
        let tmp = tempfile::tempdir().unwrap();
        let (core, mut fm, _rx) = fixture(tmp.path());
        let now = seahelm_core_types::now();
        fm.config.language = super::super::lang::Lang::Zh;
        fm.config.defaults.insert(
            super::super::Action::DeleteWorktree,
            super::super::Level::Auto,
        );
        assert!(matches!(
            fm.gate(
                super::super::Action::DeleteWorktree,
                "worktree.delete",
                &json!({"habit":"missing"}),
                now
            ),
            super::super::Gate::Deny(_)
        ));
        fm.habits.ensure_seed(&FirstMate::today(now), now).unwrap();
        let mut book = fm.habits.load(habits::GLOBAL, &FirstMate::today(now));
        let offer = fm.offers.raise(
            habits::GLOBAL,
            habits::SEED_ID,
            habits::HabitLevel::Auto,
            "grant",
        );
        let Some(habits::OfferAnswer::Accepted(grant)) =
            fm.offers.answer(&offer.payload, Some("yes:auto"))
        else {
            panic!("grant")
        };
        book.promote(grant, &FirstMate::today(now)).unwrap();
        fm.save_book(&book, now);
        assert_eq!(
            book.level(book.get(habits::SEED_ID).unwrap()),
            habits::HabitLevel::Auto
        );
        assert!(matches!(
            fm.gate(
                super::super::Action::DeleteWorktree,
                "worktree.delete",
                &json!({"habit":habits::SEED_ID,"worktree_path":"/nonexistent/wt"}),
                now
            ),
            super::super::Gate::Queued(_)
        ));
        let cards = rpc(&core, "cards.list", json!({})).unwrap();
        assert!(cards["cards"][0]["message"]
            .as_str()
            .unwrap()
            .contains("[习惯: delete-merged-clean]"));
    }
    #[test]
    fn routing_refuses_non_first_mate_and_proposals_refuse_replacement_and_unflagged_prose() {
        let tmp = tempfile::tempdir().unwrap();
        let (core, mut fm, _rx) = fixture(tmp.path());
        assert!(rpc(&core, "habits.propose", json!({}))
            .unwrap_err()
            .message
            .contains("only First Mate"));
        let now = seahelm_core_types::now();
        fm.habits.ensure_seed(&FirstMate::today(now), now).unwrap();
        assert!(fm
            .propose_habit(
                json!({"id":habits::SEED_ID,"when":{"pr":"merged"},"do":"delete_worktree"}),
                now
            )
            .unwrap_err()
            .message
            .contains("already exists"));
        assert!(fm.propose_habit(json!([]), now).is_err());
        assert!(fm
            .propose_habit(
                json!({"id":"tagged","when":{"judgement":"docs only"},"do":"keep"}),
                now
            )
            .is_err());
        assert!(fm
            .propose_habit(
                json!({"id":"docs","when":"docs only","do":"delete_worktree"}),
                now
            )
            .unwrap_err()
            .message
            .contains("judgement"));
        let book = habits::Book::parse(
            habits::GLOBAL,
            "- id: bad\n  when: merged\n  do: delete_worktree\n  level: ask\n",
            &Default::default(),
        );
        assert!(book.habits.is_empty());
        assert_eq!(book.invalid.len(), 1);
    }
    #[test]
    fn zh_sweep_inventory_and_promotion_answer_by_index_through_core() {
        use super::super::{budget, habits::HabitLevel, inventory, sweep};
        let tmp = tempfile::tempdir().unwrap();
        let (core, mut fm, rx) = fixture(tmp.path());
        let now = seahelm_core_types::now();
        fm.config.language = super::super::lang::Lang::Zh;
        fm.habits.ensure_seed(&FirstMate::today(now), now).unwrap();
        let candidate = sweep::Candidate {
            path: "/nonexistent/wt".into(),
            repo: "/nonexistent/repo".into(),
            branch: "feature".into(),
            facts: Default::default(),
        };
        let batch = sweep::Batch::new(
            "test",
            vec![sweep::Routed {
                candidate: candidate.clone(),
                decision: habits::Decision {
                    key: habits::GLOBAL.into(),
                    id: habits::SEED_ID.into(),
                    level: HabitLevel::Ask,
                },
            }],
        );
        let (message, options) = batch.card();
        let sweep_payload = batch.payload.clone();
        fm.put_card(
            CardKind::Approval,
            &sweep_payload,
            message,
            options,
            budget::Class::Answering,
            now,
        );
        fm.batches.insert(sweep_payload.clone(), batch);
        let (inventory_cards, _) = fm
            .inventory
            .raise("test", vec![(inventory::Group::Merged, vec![candidate])]);
        let card = &inventory_cards[0];
        let inventory_payload = card.payload.clone();
        let (message, options) = card.render(1, 1);
        fm.put_card(
            CardKind::Approval,
            &inventory_payload,
            message,
            options,
            budget::Class::Answering,
            now,
        );
        let offer = fm
            .offers
            .raise(habits::GLOBAL, habits::SEED_ID, HabitLevel::Auto, "test");
        fm.put_card(
            CardKind::Approval,
            &offer.payload,
            "promote".into(),
            offer.options(),
            budget::Class::Answering,
            now,
        );
        for payload in [&sweep_payload, &inventory_payload, &offer.payload] {
            let cards = rpc(&core, "cards.list", json!({})).unwrap();
            let card = cards["cards"]
                .as_array()
                .unwrap()
                .iter()
                .find(|c| c["payload"] == payload.as_str())
                .unwrap();
            assert!(rpc(&core, "cards.answer", json!({"id":card["id"],"index":1})).is_ok());
            let msg = rx.recv_timeout(std::time::Duration::from_secs(1)).unwrap();
            fm.handle(msg);
        }
        assert!(!fm.batches.contains_key(&sweep_payload));
        assert!(!fm.inventory.contains(&inventory_payload));
        assert!(!fm.offers.contains(&offer.payload));
        assert!(fm
            .habits
            .load(habits::GLOBAL, &FirstMate::today(now))
            .habits
            .iter()
            .any(|h| h.act == habits::Do::Keep));
    }
    #[test]
    fn dismissal_does_not_count_as_an_answer_or_latency() {
        let tmp = tempfile::tempdir().unwrap();
        let (_core, mut fm, _rx) = fixture(tmp.path());
        let now = seahelm_core_types::now();
        let result = fm
            .propose_habit(json!({"id":"docs","when":{"pr":"merged"},"do":"keep"}), now)
            .unwrap();
        let before = fm.budget.tuned.clone();
        fm.answered(result["card"].as_str().unwrap(), None, None, now + 1.0);
        assert_eq!(fm.budget.tuned, before);
    }
    #[test]
    fn rule_approvals_only_teach_response_timing_and_invalid_files_get_a_note() {
        let tmp = tempfile::tempdir().unwrap();
        let (core, mut fm, _rx) = fixture(tmp.path());
        let now = seahelm_core_types::now();
        let payload = "autopilot-rule";
        fm.approvals.insert(
            payload.into(),
            super::super::Approval {
                action: super::super::Action::DeleteWorktree,
                method: "worktree.delete".into(),
                params: json!({}),
                summary: "rule cleanup".into(),
            },
        );
        fm.put_card(
            CardKind::Approval,
            payload,
            "cleanup".into(),
            vec!["Approve".into(), "Reject".into()],
            budget::Class::Answering,
            now,
        );
        // An unknown key is not a selectable answer through the registry.
        let cards = rpc(&core, "cards.list", json!({})).unwrap();
        assert!(rpc(
            &core,
            "cards.answer",
            json!({"id":cards["cards"][0]["id"],"option":"approve"})
        )
        .is_err());
        // Remove the action before handling the recorded response: no deletion or model turn.
        fm.approvals.remove(payload);
        fm.answered(payload, Some("Approve"), None, now + 1.0);
        assert_eq!((fm.budget.tuned.accepted, fm.budget.tuned.declined), (0, 0));
        assert_eq!((fm.budget.tuned.answered, fm.budget.tuned.fast), (1, 1));
        std::fs::create_dir_all(&fm.habits.dir).unwrap();
        std::fs::write(
            fm.habits.path(habits::GLOBAL),
            "- id: bad\n  when: merged\n  do: delete_worktree\n  level: ask\n",
        )
        .unwrap();
        fm.check_hand_edits(now);
        let timeline = rpc(
            &core,
            "message.snapshot",
            json!({"pane_session_key":policy::SESSION}),
        )
        .unwrap();
        assert!(timeline["messages"]
            .as_array()
            .unwrap()
            .iter()
            .any(|m| m["kind"] == "note"
                && m["text"]
                    .as_str()
                    .unwrap_or_default()
                    .contains("invalid entry")));
    }
    #[test]
    fn due_review_uses_the_capped_delivery_payload_without_starting_a_session() {
        let tmp = tempfile::tempdir().unwrap();
        let (core, mut fm, _rx) = fixture(tmp.path());
        let now = 200000.0;
        fm.budget.review_enabled_at = 100.0;
        core.presence_signal(now - 1801.0, None);
        let records: Vec<_> = (0..300)
            .map(|i| {
                let mut record =
                    observations::Record::new("worktree.removed", observations::By::User).with(
                        "facts",
                        json!({"pr":"merged","idle_days":2,"days_since_merge":3,"unpushed":0}),
                    );
                record.at = iso8601(now - 100.0);
                record.branch = format!("feat/{i}");
                record.worktree = format!("/nonexistent/{i}");
                record
            })
            .collect();
        let lines = records
            .iter()
            .map(|r| serde_json::to_string(r).unwrap())
            .collect::<Vec<_>>()
            .join("\n");
        std::fs::write(fm.dir.join(observations::FILE_NAME), lines).unwrap();
        let text = fm.review_text_if_due(now).unwrap();
        assert!(text.len() <= REVIEW_BYTES);
        let v: Value = serde_json::from_str(text.split_once('\n').unwrap().1).unwrap();
        assert_eq!(v["observations"][0]["count"], 300);
        assert_eq!(v["observations"][0]["distinct_worktrees"], 300);
        core.presence_signal(now, None);
        assert!(fm.review_text_if_due(now).is_none());
        fm.review_if_due(now);
        assert_eq!(fm.budget.last_review, 0.0);
    }
}
