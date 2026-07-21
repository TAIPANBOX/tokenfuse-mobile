import Foundation

/// A thin typed client for the TokenFuse Cloud control plane. Reads use a bearer
/// token (org key today; a paired device token in B3). Kept deliberately small
/// and dependency-free; it mirrors mobile/ios/openapi.json.
struct APIClient: Sendable {
    let baseURL: URL
    let token: String
    let session: URLSession

    init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    enum ClientError: LocalizedError {
        case http(Int)
        case notHTTP
        /// A 402 denial from the entitlements gate, decoded into its typed body
        /// so callers can key an upgrade CTA off `feature`/`upgradeUrl`.
        case planRequired(PlanRequiredError)
        /// The request URL could not be assembled. Defensive: the base URL is
        /// validated and the path is already percent-encoded, so this should be
        /// unreachable.
        case badURL

        var errorDescription: String? {
            switch self {
            case .http(let code): return "The plane returned HTTP \(code)."
            case .notHTTP: return "No response from the plane."
            case .planRequired(let error): return "\(error.feature) requires a plan upgrade for \(error.org)."
            case .badURL: return "Could not build the request URL."
            }
        }
    }

    /// Wire envelope for a 402 `plan_required` denial: `{"error": {...}}`.
    private struct PlanRequiredResponse: Decodable {
        let error: PlanRequiredError
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.notHTTP }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 402, let planRequired = try? decoder.decode(PlanRequiredResponse.self, from: data) {
                throw ClientError.planRequired(planRequired.error)
            }
            throw ClientError.http(http.statusCode)
        }
        return try decoder.decode(T.self, from: data)
    }

    func runs() async throws -> [RunAgg] { try await get("v1/runs") }
    func summary() async throws -> Summary { try await get("v1/summary") }
    func budgets() async throws -> [String: Int64] { try await get("v1/budgets") }

    /// Burn-rate buckets for the whole org (`run == nil`) or a single run.
    func series(run: String?, window: String, step: String) async throws -> [SeriesBucket] {
        var query = [URLQueryItem(name: "window", value: window), URLQueryItem(name: "step", value: step)]
        if let run { query.append(URLQueryItem(name: "run", value: run)) }
        return try await get("v1/series", query: query)
    }

    /// The caller org's per-agent spend rollup, highest spend first.
    func agents() async throws -> [AgentAgg] { try await get("v1/agents") }

    /// The caller org's FinOps savings totals.
    func savings() async throws -> SavingsSummary { try await get("v1/savings") }

    /// Runs at or above `pct` of their central budget (server default when `nil`).
    func alerts(pct: Double? = nil) async throws -> [Alert] {
        var query: [URLQueryItem] = []
        if let pct { query.append(URLQueryItem(name: "pct", value: String(pct))) }
        return try await get("v1/alerts", query: query)
    }

    /// The caller org's open incidents, most-recently-seen first.
    func incidents() async throws -> [Incident] { try await get("v1/incidents") }

    /// The control-catalog-vs-live-evidence compliance pack. Paid feature.
    func compliance() async throws -> ComplianceReport { try await get("v1/compliance") }

    /// The regulator evidence pack (EU AI Act / SR 11-7 / SOC 2). Paid feature.
    func complianceEvidence() async throws -> EvidencePackResponse { try await get("v1/compliance/evidence") }

    /// The caller org's tamper-evident audit trail, oldest first. Paid feature.
    func audit() async throws -> [AuditEntry] { try await get("v1/audit") }

    /// Verifies the caller org's audit chain end-to-end. Paid feature.
    func auditVerify() async throws -> AuditVerifyResponse { try await get("v1/audit/verify") }

    /// A signed manifest over the caller org's audit chain tip. Paid feature.
    func auditManifest() async throws -> AuditManifest { try await get("v1/audit/manifest") }

    /// Replay of one run: its event timeline joined with incidents + audit. Paid feature.
    func replay(run: String) async throws -> ReplayResponse { try await get("v1/replay/\(run)") }

    /// The relay's bounded, pre-computed exception queue (`GET /relay/v1/exceptions`,
    /// docs/PHASE5.md W3): aggregates plus only at-risk/near-cap/over-cap/
    /// runaway/pending-approval items, never the full run list. Meaningful
    /// only when `baseURL` is a relay, not a direct Cloud plane, since the
    /// relay is the only server that implements this path; reuses the same
    /// `get` helper (bearer auth, snake_case decode) as every other read.
    func exceptions() async throws -> ExceptionSnapshot { try await get("relay/v1/exceptions") }

    /// The relay's second bounded, pre-computed read surface
    /// (`GET /relay/v1/money`, `exceptions.rs::MoneySnapshot`): fleet totals,
    /// the FinOps savings roll-up, a short burn series and the per-agent
    /// roll-up, each agent carrying both what it costs and how it is behaving.
    ///
    /// It exists because the rule the relay defends is "never proxy a fleet
    /// browse", not "hide the money": per-agent figures are bounded by the
    /// number of agents, not the number of runs, so they can be served without
    /// reopening the `/v1/runs` choke the relay was built to close. Like
    /// `exceptions()`, meaningful only against a relay, and served from the
    /// same bearer-auth, snake_case-decoding `get` helper as every other read.
    func money() async throws -> MoneySnapshot { try await get("relay/v1/money") }
}
