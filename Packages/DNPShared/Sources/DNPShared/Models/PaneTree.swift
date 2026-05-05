import Foundation

/// Direction of a `PaneTree.split` node — `.horizontal` arranges its
/// children side-by-side (a vertical divider runs between them, the user
/// drags it left/right), `.vertical` stacks them top/bottom (the divider
/// runs horizontally, the user drags it up/down).
///
/// Naming convention: "horizontal split" describes the SHAPE of the
/// arrangement (children laid out along the horizontal axis), not the
/// orientation of the divider — same vocabulary tmux/Emacs use.
public enum PaneOrientation: String, Codable, Hashable, Sendable {
    case horizontal
    case vertical
}

/// Recursive layout tree for the workspace's terminal panes.
///
/// A leaf is a single session id (one terminal). A split is a binary
/// node with two children, an orientation, and a fraction in [0,1] that
/// stores the leading child's relative size as a fraction of the parent's
/// available extent.
///
/// All mutations return a new tree — the type is immutable so SwiftUI
/// observes value changes cleanly via the `@Published` wrapper on
/// `WorkspaceController.paneTree`.
///
/// Lives in DNPShared rather than the Mac app because the recursive
/// shape is pure data with no platform dependencies; the shared package
/// is the right home for reusable value types and unlocks unit testing.
public indirect enum PaneTree: Codable, Hashable, Sendable {
    case leaf(UUID)
    case split(direction: PaneOrientation,
               leading: PaneTree,
               trailing: PaneTree,
               fraction: CGFloat)

    // MARK: - Inspection

    /// Number of leaves under this node — 1 for a leaf, sum of children
    /// for a split. Drives the 4-pane cap (`canAddPane`).
    public var leafCount: Int {
        switch self {
        case .leaf: return 1
        case .split(_, let l, let t, _): return l.leafCount + t.leafCount
        }
    }

    /// All leaf session ids in tree-walk order (leading-first depth-first).
    public var leaves: [UUID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, let l, let t, _): return l.leaves + t.leaves
        }
    }

    /// First leaf encountered in a leading-first walk — used as the
    /// fallback focus target when the previously focused leaf is closed.
    public var firstLeaf: UUID? {
        leaves.first
    }

    public func contains(_ id: UUID) -> Bool {
        leaves.contains(id)
    }

    // MARK: - Mutation

    /// Replace the leaf whose id is `target` by `replacement`. If the
    /// leaf isn't in the tree, returns `self` unchanged. The tree is
    /// rebuilt structurally so callers can compare value-by-value.
    public func replacing(_ target: UUID, with replacement: PaneTree) -> PaneTree {
        switch self {
        case .leaf(let id):
            return id == target ? replacement : self
        case .split(let dir, let l, let t, let f):
            return .split(direction: dir,
                          leading: l.replacing(target, with: replacement),
                          trailing: t.replacing(target, with: replacement),
                          fraction: f)
        }
    }

    /// Remove the leaf identified by `id`. The parent split's other
    /// child takes the parent's place — same convention tmux/Emacs use
    /// when the user kills a pane. Returns `nil` if the only leaf in
    /// the tree was removed (caller should drop back to single-pane
    /// mode).
    public func removing(_ id: UUID) -> PaneTree? {
        switch self {
        case .leaf(let leafId):
            return leafId == id ? nil : self
        case .split(let dir, let l, let t, let f):
            let nl = l.removing(id)
            let nt = t.removing(id)
            switch (nl, nt) {
            case (nil, nil):       return nil      // both gone (shouldn't happen for distinct ids, but safe)
            case (nil, let only?): return only     // leading died → trailing replaces parent
            case (let only?, nil): return only     // trailing died → leading replaces parent
            case (let l?, let t?): return .split(direction: dir, leading: l, trailing: t, fraction: f)
            }
        }
    }

    /// Swap the positions of two leaves in the tree. Useful for
    /// "swap with the other pane" affordances on the pane header.
    public func swapping(_ a: UUID, _ b: UUID) -> PaneTree {
        switch self {
        case .leaf(let id):
            if id == a { return .leaf(b) }
            if id == b { return .leaf(a) }
            return self
        case .split(let dir, let l, let t, let f):
            return .split(direction: dir,
                          leading: l.swapping(a, b),
                          trailing: t.swapping(a, b),
                          fraction: f)
        }
    }

    /// Drop any leaf where `keep(id)` returns false; collapse splits
    /// whose sole surviving child becomes nil. Used to scrub stale
    /// (closed/ended) sessions out of the tree after a session-list
    /// mutation. Returns `nil` if no leaf survives.
    public func pruning(keep: (UUID) -> Bool) -> PaneTree? {
        switch self {
        case .leaf(let id):
            return keep(id) ? self : nil
        case .split(let dir, let l, let t, let f):
            let nl = l.pruning(keep: keep)
            let nt = t.pruning(keep: keep)
            switch (nl, nt) {
            case (nil, nil):       return nil
            case (nil, let only?): return only
            case (let only?, nil): return only
            case (let l?, let t?): return .split(direction: dir, leading: l, trailing: t, fraction: f)
            }
        }
    }

    /// Update the fraction stored at the split node whose subtrees
    /// match `targetLeading` and `targetTrailing` exactly. Subtree
    /// equality is well-defined (PaneTree is `Hashable`), so the match
    /// is unambiguous even when nested splits share a direction — the
    /// previous "closest-to-leaf" heuristic could update two fractions
    /// from one drag in `[A | B] | C` style layouts.
    ///
    /// Callers (the divider's `Binding` setter) capture the leading and
    /// trailing values of the split node they are currently rendering
    /// at view-build time, so the mutation lands on exactly the split
    /// the user dragged.
    public func settingFraction(_ value: CGFloat,
                                forSplitWithLeading targetLeading: PaneTree,
                                trailing targetTrailing: PaneTree) -> PaneTree {
        switch self {
        case .leaf:
            return self
        case .split(let dir, let l, let t, let f):
            // Direct hit: this IS the target split.
            if l == targetLeading && t == targetTrailing {
                return .split(direction: dir,
                              leading: l,
                              trailing: t,
                              fraction: value)
            }
            // Otherwise recurse into both children so the mutation can
            // land deeper in the tree. Both branches may be no-ops if
            // the target sits in the other subtree.
            return .split(direction: dir,
                          leading: l.settingFraction(value,
                                                      forSplitWithLeading: targetLeading,
                                                      trailing: targetTrailing),
                          trailing: t.settingFraction(value,
                                                       forSplitWithLeading: targetLeading,
                                                       trailing: targetTrailing),
                          fraction: f)
        }
    }
}
