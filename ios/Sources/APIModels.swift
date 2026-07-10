import Foundation

// Typed models mirroring the control-plane contract (mobile/ios/openapi.json,
// generated from crates/cloud). Decoded with `.convertFromSnakeCase`, so the
// wire's `run_id` / `spent_microusd` map to these camelCase properties. Money
// is microdollars on the wire; converted to dollars for display.

struct RunAgg: Codable, Identifiable, Sendable, Hashable {
    let runId: String
    let model: String
    let spentMicrousd: Int64
    let calls: Int
    let cacheHits: Int
    let steps: Int
    let lastSeenMillis: Int64
    let killed: Bool
    /// Logical agent this run is attributed to (P2); `""` when the gateway
    /// didn't tag the calls (folded into the "unattributed" bucket). The
    /// server sends `#[serde(default)]`, so decode tolerantly — absent on
    /// older snapshots.
    let agentId: String

    var id: String { runId }

    init(
        runId: String, model: String, spentMicrousd: Int64, calls: Int, cacheHits: Int,
        steps: Int, lastSeenMillis: Int64, killed: Bool, agentId: String = ""
    ) {
        self.runId = runId
        self.model = model
        self.spentMicrousd = spentMicrousd
        self.calls = calls
        self.cacheHits = cacheHits
        self.steps = steps
        self.lastSeenMillis = lastSeenMillis
        self.killed = killed
        self.agentId = agentId
    }

    private enum CodingKeys: String, CodingKey {
        case runId, model, spentMicrousd, calls, cacheHits, steps, lastSeenMillis, killed, agentId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runId = try c.decode(String.self, forKey: .runId)
        model = try c.decode(String.self, forKey: .model)
        spentMicrousd = try c.decode(Int64.self, forKey: .spentMicrousd)
        calls = try c.decode(Int.self, forKey: .calls)
        cacheHits = try c.decode(Int.self, forKey: .cacheHits)
        steps = try c.decode(Int.self, forKey: .steps)
        lastSeenMillis = try c.decode(Int64.self, forKey: .lastSeenMillis)
        killed = try c.decode(Bool.self, forKey: .killed)
        agentId = try c.decodeIfPresent(String.self, forKey: .agentId) ?? ""
    }
}

/// Per-agent spend rollup (P2, `/v1/agents`), folded from an org's `RunAgg`s by
/// `agentId`. `""` is the explicit "unattributed" bucket.
struct AgentAgg: Codable, Identifiable, Sendable, Hashable {
    let agentId: String
    let spentMicrousd: Int64
    let calls: Int64
    let runs: Int64
    let lastSeenMillis: Int64

    var id: String { agentId }
    var spent: Double { spentMicrousd.usd }
}

/// Per-org FinOps savings summary (P2, `/v1/savings`). `totalSaved` is the
/// marketing headline: blocked spend + cache savings + router savings.
struct SavingsSummary: Codable, Sendable, Hashable {
    let blockedSpendMicrousd: Int64
    let cacheSavedMicrousd: Int64
    let routerSavedMicrousd: Int64
    let budgetBreaks: Int64
    let totalSavedMicrousd: Int64

    var blockedSpend: Double { blockedSpendMicrousd.usd }
    var cacheSaved: Double { cacheSavedMicrousd.usd }
    var routerSaved: Double { routerSavedMicrousd.usd }
    var totalSaved: Double { totalSavedMicrousd.usd }
}

/// A run at or above its alert threshold (`/v1/alerts`).
struct Alert: Codable, Sendable, Hashable {
    let runId: String
    let spentMicrousd: Int64
    let budgetMicros: Int64
    let fraction: Double
    let killed: Bool
}

/// An aggregated, first-class anomaly for an org (P2 incidents, `/v1/incidents`).
/// Repeated or severe detections fold into one `Incident` keyed by a stable id
/// (`"{kind}:{run_or_agent}"`) so later triggers bump `occurrences` in place.
struct Incident: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let org: String
    /// The run this incident is scoped to; `nil` when org-scoped (e.g. `spend_spike`).
    let runId: String?
    /// The agent attributed at trip time, when the gateway tagged the run.
    let agentId: String?
    /// Detector kind: `budget_exhausted` | `sustained_loop` | `spend_spike` | `fanout_explosion`.
    let kind: String
    let severity: String
    let firstSeenMillis: Int64
    let lastSeenMillis: Int64
    let occurrences: Int64
    let acknowledged: Bool
    /// Epoch millis of the last push fired for this incident; `0` until first notified.
    let lastNotifiedMillis: Int64
}

struct Summary: Codable, Sendable {
    let runs: Int
    let calls: Int
    let spentMicrousd: Int64
}

/// One time bucket of the burn-rate series (`/v1/series`).
struct SeriesBucket: Codable, Sendable, Identifiable {
    let t: Int64  // bucket start, epoch millis
    let costMicrousd: Int64
    let calls: Int
    let blocked: Int

    var id: Int64 { t }
    var cost: Double { costMicrousd.usd }
}

// MARK: - Governance (compliance, audit, replay)

/// One control's realized evidence within a `ComplianceReport`.
struct ControlEvidence: Codable, Identifiable, Sendable, Hashable {
    let controlId: String
    let title: String
    /// Honesty classification, lowercase: `enforced` | `partial` | `documented`.
    let enforcement: String
    /// Watched wire `decision` → times it fired.
    let decisionCounts: [String: Int64]
    /// Watched finding `kind` → times it appeared.
    let findingCounts: [String: Int64]
    /// Cloud incidents aggregating into this control.
    let incidentCount: Int64
    let covered: Bool
    let evidenceSeen: Bool

    var id: String { controlId }
}

/// The control-catalog-vs-live-evidence pack (`/v1/compliance`, paid feature).
/// Evidence, not a certification — see `generatedNote`.
struct ComplianceReport: Codable, Sendable, Hashable {
    let generatedNote: String
    /// `[frameworkId, humanName, version]` triples the mappings were cited against.
    let frameworkVersions: [[String]]
    let controls: [ControlEvidence]
    let decisionsTotal: Int64
    let findingsTotal: Int64
}

/// Honesty classification for one control in a regulator evidence pack
/// (`/v1/compliance/evidence`), decided from live org data.
enum EvidenceStatus: String, Codable, Sendable, Hashable {
    case enforced = "Enforced"
    case partial = "Partial"
    case documented = "Documented"
}

/// One control's entry in a regulator evidence-pack framework section: the
/// TokenFuse control plus the external clause it's cited against.
struct EvidenceControl: Codable, Sendable, Hashable {
    let control: String
    let status: EvidenceStatus
    let evidence: String
}

/// A regulator evidence pack (`/v1/compliance/evidence`, paid feature): the same
/// live data behind `/v1/compliance`, mapped to EU AI Act, SR 11-7, and SOC 2.
struct EvidencePackResponse: Codable, Sendable, Hashable {
    let generatedNote: String
    let org: String
    let euAiAct: [EvidenceControl]
    let sr117: [EvidenceControl]
    let soc2: [EvidenceControl]
    /// Whether this org's audit chain verifies end-to-end right now.
    let auditChainVerified: Bool
    /// 0-based index of the first broken link, when `auditChainVerified` is `false`.
    let auditBreakIndex: Int?
    let auditEntries: Int64
    let decisionsTotal: Int64
    let incidentsTotal: Int64
}

/// One entry in the caller org's tamper-evident audit trail (`/v1/audit`).
struct AuditEntry: Codable, Identifiable, Sendable, Hashable {
    let seq: Int64
    let tsMillis: Int64
    let actor: String
    let action: String
    let subject: String
    let detail: String
    let prevHash: String
    let entryHash: String

    var id: Int64 { seq }
}

/// Result of an audit-chain integrity check (`/v1/audit/verify`). `ok` is
/// `true` for an intact (or empty) chain; otherwise `breakIndex` is the
/// 0-based position of the first broken link.
struct AuditVerifyResponse: Codable, Sendable, Hashable {
    let ok: Bool
    let breakIndex: Int?
}

/// A cryptographically-signed manifest over an org's audit chain tip
/// (`/v1/audit/manifest`, paid feature). An auditor re-derives the signed
/// bytes from these fields and verifies `signatureB64` against
/// `publicKeyB64` with any standard ES256 tool.
struct AuditManifest: Codable, Sendable, Hashable {
    let org: String
    let tipSeq: Int64
    let tipHash: String
    let entryCount: Int64
    let signedAtMillis: Int64
    /// Always `"ES256"` (ECDSA P-256 / SHA-256).
    let algorithm: String
    let signatureB64: String
    let publicKeyB64: String
}

/// Minimal, dependency-free JSON value — used only for `ReplayEvent.data`'s
/// free-form payload.
enum JSONValue: Codable, Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }
}

/// One parsed NDJSON line from the agent-event export (`/v1/replay/{run}`).
/// Every field is best-effort on the wire (`#[serde(default)]`), so decode
/// tolerantly — all properties are optional.
struct ReplayEvent: Codable, Sendable, Hashable {
    let agentId: String?
    let data: [String: JSONValue]?
    let onBehalfOf: [String]?
    let prevHash: String?
    let runId: String?
    let schema: String?
    let severity: String?
    let source: String?
    let ts: String?
    let `type`: String?
}

/// Response body for `GET /v1/replay/{run}` (paid feature): one run's ordered
/// agent-event timeline, joined with its incidents and referencing audit entries.
struct ReplayResponse: Codable, Sendable, Hashable {
    let runId: String
    /// Whether `TOKENFUSE_CLOUD_REPLAY_EVENTS` is configured on the server.
    let configured: Bool
    /// This run's agent-events, ts-ascending.
    let events: [ReplayEvent]
    let eventCount: Int
    /// NDJSON lines that failed to parse (skipped, not counted in `events`).
    let malformedSkipped: Int
    /// This run's open incidents.
    let incidents: [Incident]
    /// Audit-chain entries whose subject is this run, oldest first.
    let audit: [AuditEntry]
}

/// The `error` object of a 402 `plan_required` denial from the entitlements
/// gate (wire envelope is `{"error": PlanRequiredError}`).
struct PlanRequiredError: Codable, Sendable, Hashable {
    let `type`: String
    /// The gated feature.
    let feature: String
    /// The org that needs an upgrade.
    let org: String
    /// Where to upgrade.
    let upgradeUrl: String
}

extension Int64 {
    /// Microdollars → dollars.
    var usd: Double { Double(self) / 1_000_000 }
}

extension Array where Element == SeriesBucket {
    /// Recent burn rate in $/min — the last non-empty bucket, scaled to a minute.
    func burnRatePerMin(stepSeconds: Double) -> Double {
        guard let last = last(where: { $0.costMicrousd > 0 }) else { return 0 }
        return last.cost / (stepSeconds / 60)
    }
}
