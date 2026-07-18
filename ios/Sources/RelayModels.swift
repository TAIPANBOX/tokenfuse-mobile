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

    var id: String { key }
    var spent: Double { spentMicrousd.usd }
    var budget: Double? { budgetMicros.map { $0.usd } }
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
