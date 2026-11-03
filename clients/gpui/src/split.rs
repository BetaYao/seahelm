//! A worktree's panes as a binary split tree, as the macOS app's
//! `SplitTree`: leaves are panes, inner nodes split their space in two
//! along an axis at a ratio. Pure data; the workspace draws it from
//! [`SplitTree::frames`] and moves focus with [`SplitTree::neighbour`].

/// A pane, stable for the life of the tree. Leaf 0 is the worktree's
/// first pane.
pub type LeafId = u32;

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Axis {
    /// Side by side: the split line is vertical.
    Horizontal,
    /// One above the other.
    Vertical,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Direction {
    Left,
    Right,
    Up,
    Down,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
enum Node {
    Leaf(LeafId),
    Split { axis: Axis, ratio: f32, a: Box<Node>, b: Box<Node> },
}

/// A rectangle in the tree's own space, 0..1 on both axes.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

impl Rect {
    pub const UNIT: Rect = Rect { x: 0.0, y: 0.0, w: 1.0, h: 1.0 };

    fn centre(&self) -> (f32, f32) {
        (self.x + self.w / 2.0, self.y + self.h / 2.0)
    }
}

/// Where a split's divider is, and which split it moves.
#[derive(Clone, Debug, PartialEq)]
pub struct Divider {
    /// The path from the root to the split: false is `a`, true is `b`.
    pub path: Vec<bool>,
    pub axis: Axis,
    /// The whole split's area: a drag's ratio is measured across it.
    pub area: Rect,
    /// Where the line falls: x for a horizontal split, y for a vertical one.
    pub at: f32,
}

pub const MIN_RATIO: f32 = 0.1;
pub const MAX_RATIO: f32 = 0.9;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SplitTree {
    root: Node,
    pub focused: LeafId,
    next: LeafId,
}

impl Default for SplitTree {
    fn default() -> Self {
        SplitTree { root: Node::Leaf(0), focused: 0, next: 1 }
    }
}

impl SplitTree {
    pub fn leaves(&self) -> Vec<LeafId> {
        let mut out = Vec::new();
        collect(&self.root, &mut out);
        out
    }

    pub fn len(&self) -> usize {
        self.leaves().len()
    }

    /// Split the focused pane in two along `axis`, evenly; the new pane
    /// goes right of / below it and takes focus.
    pub fn split(&mut self, axis: Axis) -> LeafId {
        let new = self.next;
        self.next += 1;
        let target = self.focused;
        replace_leaf(&mut self.root, target, &mut |old| Node::Split {
            axis,
            ratio: 0.5,
            a: Box::new(Node::Leaf(old)),
            b: Box::new(Node::Leaf(new)),
        });
        self.focused = new;
        new
    }

    /// Take a pane out; its sibling takes its parent's place. The last pane
    /// stays (a worktree always has one). Focus goes to the nearest pane
    /// that was beside it.
    pub fn remove(&mut self, leaf: LeafId) -> bool {
        if self.len() <= 1 || !self.leaves().contains(&leaf) {
            return false;
        }
        let before = self.frames();
        let gone = before.iter().find(|(l, _)| *l == leaf).map(|(_, r)| *r);
        self.root = without(std::mem::replace(&mut self.root, Node::Leaf(0)), leaf).expect("a leaf remains");
        if self.focused == leaf || !self.leaves().contains(&self.focused) {
            let leaves = self.leaves();
            self.focused = match gone {
                Some(r) => {
                    let (cx, cy) = r.centre();
                    let frames = self.frames();
                    *leaves
                        .iter()
                        .min_by(|a, b| {
                            let d = |l: &LeafId| {
                                let f = frames.iter().find(|(x, _)| x == l).unwrap().1;
                                let (x, y) = f.centre();
                                (x - cx).powi(2) + (y - cy).powi(2)
                            };
                            d(a).total_cmp(&d(b))
                        })
                        .unwrap()
                }
                None => leaves[0],
            };
        }
        true
    }

    /// Every pane's rectangle.
    pub fn frames(&self) -> Vec<(LeafId, Rect)> {
        let mut out = Vec::new();
        frames(&self.root, Rect::UNIT, &mut out);
        out
    }

    /// Every split's divider.
    pub fn dividers(&self) -> Vec<Divider> {
        let mut out = Vec::new();
        dividers(&self.root, Rect::UNIT, &mut Vec::new(), &mut out);
        out
    }

    /// Move a divider; the ratio is clamped as the macOS app clamps it.
    pub fn set_ratio(&mut self, path: &[bool], ratio: f32) {
        let mut node = &mut self.root;
        for &right in path {
            match node {
                Node::Split { a, b, .. } => node = if right { b } else { a },
                Node::Leaf(_) => return,
            }
        }
        if let Node::Split { ratio: r, .. } = node {
            *r = ratio.clamp(MIN_RATIO, MAX_RATIO);
        }
    }

    /// Back to an even split (a divider's double-click).
    pub fn equalize(&mut self, path: &[bool]) {
        self.set_ratio(path, 0.5);
    }

    /// The pane next to the focused one in `dir`: of the panes whose edge
    /// touches it on that side and overlap it across, the one most in line
    /// with its centre.
    pub fn neighbour(&self, dir: Direction) -> Option<LeafId> {
        let frames = self.frames();
        let me = frames.iter().find(|(l, _)| *l == self.focused)?.1;
        const EPS: f32 = 1e-4;
        let (cx, cy) = me.centre();
        frames
            .iter()
            .filter(|(l, _)| *l != self.focused)
            .filter(|(_, r)| match dir {
                Direction::Left => (r.x + r.w - me.x).abs() < EPS && overlaps(r.y, r.h, me.y, me.h),
                Direction::Right => (me.x + me.w - r.x).abs() < EPS && overlaps(r.y, r.h, me.y, me.h),
                Direction::Up => (r.y + r.h - me.y).abs() < EPS && overlaps(r.x, r.w, me.x, me.w),
                Direction::Down => (me.y + me.h - r.y).abs() < EPS && overlaps(r.x, r.w, me.x, me.w),
            })
            .min_by(|(_, a), (_, b)| {
                let off = |r: &Rect| match dir {
                    Direction::Left | Direction::Right => (r.centre().1 - cy).abs(),
                    Direction::Up | Direction::Down => (r.centre().0 - cx).abs(),
                };
                off(a).total_cmp(&off(b))
            })
            .map(|(l, _)| *l)
    }
}

fn overlaps(a: f32, alen: f32, b: f32, blen: f32) -> bool {
    a < b + blen - 1e-4 && b < a + alen - 1e-4
}

fn collect(n: &Node, out: &mut Vec<LeafId>) {
    match n {
        Node::Leaf(l) => out.push(*l),
        Node::Split { a, b, .. } => {
            collect(a, out);
            collect(b, out);
        }
    }
}

fn replace_leaf(n: &mut Node, target: LeafId, with: &mut dyn FnMut(LeafId) -> Node) -> bool {
    match n {
        Node::Leaf(l) if *l == target => {
            *n = with(*l);
            true
        }
        Node::Leaf(_) => false,
        Node::Split { a, b, .. } => replace_leaf(a, target, with) || replace_leaf(b, target, with),
    }
}

fn without(n: Node, leaf: LeafId) -> Option<Node> {
    match n {
        Node::Leaf(l) if l == leaf => None,
        Node::Leaf(l) => Some(Node::Leaf(l)),
        Node::Split { axis, ratio, a, b } => match (without(*a, leaf), without(*b, leaf)) {
            (Some(a), Some(b)) => Some(Node::Split { axis, ratio, a: Box::new(a), b: Box::new(b) }),
            (Some(x), None) | (None, Some(x)) => Some(x),
            (None, None) => None,
        },
    }
}

fn halves(area: Rect, axis: Axis, ratio: f32) -> (Rect, Rect) {
    match axis {
        Axis::Horizontal => {
            let w = area.w * ratio;
            (Rect { w, ..area }, Rect { x: area.x + w, w: area.w - w, ..area })
        }
        Axis::Vertical => {
            let h = area.h * ratio;
            (Rect { h, ..area }, Rect { y: area.y + h, h: area.h - h, ..area })
        }
    }
}

fn frames(n: &Node, area: Rect, out: &mut Vec<(LeafId, Rect)>) {
    match n {
        Node::Leaf(l) => out.push((*l, area)),
        Node::Split { axis, ratio, a, b } => {
            let (ra, rb) = halves(area, *axis, *ratio);
            frames(a, ra, out);
            frames(b, rb, out);
        }
    }
}

fn dividers(n: &Node, area: Rect, path: &mut Vec<bool>, out: &mut Vec<Divider>) {
    if let Node::Split { axis, ratio, a, b } = n {
        let (ra, rb) = halves(area, *axis, *ratio);
        let at = match axis {
            Axis::Horizontal => rb.x,
            Axis::Vertical => rb.y,
        };
        out.push(Divider { path: path.clone(), axis: *axis, area, at });
        path.push(false);
        dividers(a, ra, path, out);
        path.pop();
        path.push(true);
        dividers(b, rb, path, out);
        path.pop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splitting_halves_the_focused_pane_and_focuses_the_new_one() {
        let mut t = SplitTree::default();
        let right = t.split(Axis::Horizontal);
        assert_eq!(t.focused, right);
        let frames = t.frames();
        assert_eq!(frames[0], (0, Rect { x: 0.0, y: 0.0, w: 0.5, h: 1.0 }));
        assert_eq!(frames[1], (right, Rect { x: 0.5, y: 0.0, w: 0.5, h: 1.0 }));
        let below = t.split(Axis::Vertical);
        assert_eq!(t.leaves(), vec![0, right, below]);
        assert_eq!(t.frames()[2].1, Rect { x: 0.5, y: 0.5, w: 0.5, h: 0.5 });
    }

    #[test]
    fn focus_moves_to_the_pane_beside() {
        let mut t = SplitTree::default();
        let right = t.split(Axis::Horizontal);
        let below = t.split(Axis::Vertical);
        assert_eq!(t.neighbour(Direction::Up), Some(right));
        assert_eq!(t.neighbour(Direction::Left), Some(0));
        assert_eq!(t.neighbour(Direction::Right), None);
        t.focused = 0;
        // Both right-hand panes touch it; the upper one is no more in line
        // than the lower, so either is right, but it must be one of them.
        assert!(matches!(t.neighbour(Direction::Right), Some(l) if l == right || l == below));
        assert_eq!(t.neighbour(Direction::Left), None);
    }

    #[test]
    fn removing_a_pane_gives_its_space_to_its_sibling() {
        let mut t = SplitTree::default();
        let right = t.split(Axis::Horizontal);
        let below = t.split(Axis::Vertical);
        assert!(t.remove(below));
        assert_eq!(t.leaves(), vec![0, right]);
        assert_eq!(t.focused, right, "focus goes to the pane that was beside it");
        assert_eq!(t.frames()[1].1, Rect { x: 0.5, y: 0.0, w: 0.5, h: 1.0 });
        assert!(t.remove(right));
        assert!(!t.remove(0), "the last pane stays");
        assert_eq!(t.leaves(), vec![0]);
        assert_eq!(t.focused, 0);
    }

    #[test]
    fn dividers_move_within_bounds() {
        let mut t = SplitTree::default();
        t.split(Axis::Horizontal);
        t.split(Axis::Vertical);
        let d = t.dividers();
        assert_eq!(d.len(), 2);
        assert_eq!(d[0].path, Vec::<bool>::new());
        assert_eq!(d[0].at, 0.5);
        assert_eq!(d[1].path, vec![true]);
        assert_eq!(d[1].area, Rect { x: 0.5, y: 0.0, w: 0.5, h: 1.0 });
        t.set_ratio(&[], 0.95);
        assert_eq!(t.dividers()[0].at, MAX_RATIO);
        t.equalize(&[]);
        assert_eq!(t.dividers()[0].at, 0.5);
    }

    #[test]
    fn leaf_ids_are_never_reused() {
        let mut t = SplitTree::default();
        let a = t.split(Axis::Horizontal);
        t.remove(a);
        let b = t.split(Axis::Horizontal);
        assert_ne!(a, b);
    }
}
