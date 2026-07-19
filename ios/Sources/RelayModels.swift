import SwiftUI

// Typed models mirroring the relay's own contract (genaryx/crates/relay/src/
// exceptions.rs's ExceptionSnapshot/ExceptionItem/Aggregates/ExceptionClass),
// fetched from `GET /relay/v1/exceptions`. Decoded with `.convertFromSnakeCase`
// like APIModels.swift's Cloud-facing types; money is microdollars on the
// wire, converted to dollars for display via the same `Int64.usd` helper.

/// The five-way taxonomy the relay's ExceptionEngine classifies every queue
/// item into (`exceptions.rs::ExceptionClass`, `#[serde(rename_all =
/// "snake_case")]`). Raw values are the literal wire strings, unaffected by
/// `.convertFromSnakeCase` (that decoding strategy only rewrites coding
/// keys, not enum raw values).
enum ExceptionClass: String, Codable, Sendable, Hashable {
    case atRisk = "at_risk"
    case nearCap = "near_cap"
    case overCap = "over_cap"
    case runaway = "runaway"
    /// Reserved on the server, no Wardryx/copilot read is wired into the
    /// relay yet (`exceptions.rs`'s own `#[allow(dead_code)]` note) - never
    /// actually emitted today. Handled here so decoding stays forward-safe.
    case pendingApproval = "pending_approval"

    /// HARD (push immediately, deterministic, never suppressible, D12.2b) vs
    /// SOFT - mirrors `exceptions.rs::is_hard` exactly.
    var isHard: Bool { self == .overCap || self == .runaway }

    var label: String {
        switch self {
        case .atRisk: return "At risk"
        case .nearCap: return "Near cap"
        case .overCap: return "Over cap"
        case .runaway: return "Runaway"
        case .pendingApproval: return "Pending approval"
        }
    }

    var symbol: String {
        switch self {
        case .atRisk: return "exclamationmark.triangle"
        case .nearCap: return "gauge.with.needle"
        case .overCap: return "fuelpump.slash"
        case .runaway: return "flame"
        case .pendingApproval: return "hourglass"
        }
    }

    var accent: Color {
        switch self {
        case .atRisk: return Palette.amber
        case .nearCap: return Palette.amber
        case .overCap, .runaway: return Palette.ember
        case .pendingApproval: return Palette.iris
        }
    }
}

/// One row in the relay's bounded, pre-computed exception queue
/// (`exceptions.rs::ExceptionItem`). `runId`/`incidentId` decide the row's
/// one action: a run-scoped item can be killed, an incident-only item (no
/// attributable run) can be acknowledged.
struct ExceptionItem: Codable, Identifiable, Sendable, Hashable {
    let key: String
    let runId: String?
    let incidentId: String?
    /// `"budget"` | `"kill"` | an incident kind (`budget_exhausted` |
    /// `sustained_loop` | `spend_spike` | `fanout_explosion`).
    let kind: String
    let `class`: ExceptionClass
    let severity: String?
    let headline: String
    let spentMicrousd: Int64
    let budgetMicros: Int64?
    let fraction: Double?
    let firstSeenUnix: Int64
    let lastSeenUnix: Int64
    let acknowledged: Bool
    let killed: Bool
    /// C3's best-effort Felyx annotation (docs/PHASE6-C3.md C3-W2,
    /// `exceptions.rs::ExceptionItem::copilot`), attached AFTER the
    /// deterministic push for a HARD item, or never at all. The relay marks
    /// it `#[serde(skip_serializing_if = "Option::is_none")]`, so it is
    /// OMITTED from the wire entirely when absent - never sent as `null`.
    /// This struct has no custom `init(from:)`, so `Codable` is fully
    /// compiler-synthesized; a plain `Optional` stored property already
    /// decodes a missing key as `nil` with no extra work, exactly like
    /// `runId`/`incidentId`/`severity`/`fraction`/`budgetMicros` above.
    let copilot: CopilotAnnotation?

    var id: String { key }
    var spent: Double { spentMicrousd.usd }
    var budget: Double? { budgetMicros.map { $0.usd } }
}

/// C3's Felyx annotation on a queue item (docs/PHASE6-C3.md C3-W1,
/// `genaryx_copilot::action::CopilotAnnotation`): a one-line summary, an
/// optional recommended action, the model's confidence, and the cross-plane
/// chain that produced it. It only ever ENRICHES a pushed/polled exception -
/// it can never suppress or delay the deterministic HARD push (that floor is
/// relay code, not this data).
///
/// `chain` is `#[serde(default)]` on the relay side: today it is always sent
/// alongside `summary`/`confidence`, but that default means a future/older
/// relay build is free to omit it. Swift's compiler-synthesized `Codable`
/// does NOT honor a stored property's default value for a missing key (only
/// `Optional` types get that for free) - so this type gets a hand-written
/// `init(from:)` that falls back to `[]` via `decodeIfPresent`, exactly so a
/// missing/omitted `chain` key can never fail decoding the whole annotation
/// (and, transitively, the whole `ExceptionItem`/`ExceptionSnapshot`).
/// `.convertFromSnakeCase` (set on the decoder in `APIClient`) still applies
/// to nested keyed containers built from a manual `init(from:)` exactly as it
/// does for synthesized ones, so `recommended_action` on the wire matches
/// `.recommendedAction` here with no explicit rename needed.
struct CopilotAnnotation: Codable, Sendable, Hashable {
    let summary: String
    let recommendedAction: CopilotRecommendedAction?
    let confidence: Double
    let chain: [String]

    private enum CodingKeys: String, CodingKey {
        case summary, recommendedAction, confidence, chain
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(String.self, forKey: .summary)
        recommendedAction = try container.decodeIfPresent(CopilotRecommendedAction.self, forKey: .recommendedAction)
        confidence = try container.decode(Double.self, forKey: .confidence)
        chain = try container.decodeIfPresent([String].self, forKey: .chain) ?? []
    }
}

/// Minimal mirror of the relay's `ProposedAction`
/// (`genaryx_copilot::action::ProposedAction`) - just the two fields the
/// queue card needs for a "suggests: <kind> <target>" chip. The wire also
/// carries `params` (arbitrary JSON), `rationale`, `confidence`,
/// `evidence_refs` and `policy_context`; `Codable`'s synthesized decode only
/// ever pulls the keys a type declares; it silently ignores every other key
/// in the JSON object, so this deliberately-small struct decodes the same
/// payload the full desktop-side type does, unaffected by the fields it
/// doesn't model.
struct CopilotRecommendedAction: Codable, Sendable, Hashable {
    let kind: String
    let target: String
}

/// Fleet-wide totals the relay pre-computes alongside the queue
/// (`exceptions.rs::Aggregates`): spend, headroom, burn rate.
struct ExceptionAggregates: Codable, Sendable, Hashable {
    let spendMicrousd: Int64
    let headroomMicrousd: Int64
    let burnRateMicrousdPerMin: Int64
    let updatedAtUnix: Int64

    var spend: Double { spendMicrousd.usd }
    var headroom: Double { headroomMicrousd.usd }
    var burnRatePerMin: Double { Double(burnRateMicrousdPerMin) / 1_000_000 }
}

/// `GET /relay/v1/exceptions`'s full response body
/// (`exceptions.rs::ExceptionSnapshot`) - the phone's ENTIRE view of the
/// fleet when paired through the relay (docs/PHASE5.md W3: "Never call
/// /v1/runs").
struct ExceptionSnapshot: Codable, Sendable, Hashable {
    let aggregates: ExceptionAggregates
    let queue: [ExceptionItem]
}
