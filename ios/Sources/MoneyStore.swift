import Foundation
import Observation

/// Loads `GET /relay/v1/money` and holds the last-known-good snapshot for the
/// Money and Agents screens.
///
/// Deliberately shaped like `ExceptionQueueStore` rather than like `RunsStore`:
/// both of these read the relay, not Cloud, so both inherit the same two rules
/// that matter on a paired device. A 401 means the device was revoked and the
/// app must go back to Connect rather than show a frozen screen behind a green
/// dot; any other failure keeps the previous snapshot on screen, because a
/// dropped request is not news and a blank money screen would read as "no
/// spend" rather than "no answer".
@MainActor
@Observable
final class MoneyStore {
    enum Phase: Equatable {
        case idle, loading, loaded, failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var aggregates: ExceptionAggregates?
    private(set) var savings: SavingsRollup?
    private(set) var agents: [AgentRollup] = []
    /// Nonzero only when the relay had to cut the agents list, with
    /// `othersSpentMicrousd` accounting for exactly what was cut. Shown, never
    /// swallowed: a list that silently stops at 200 would read as the whole
    /// fleet.
    private(set) var agentsTruncated: Int = 0
    private(set) var othersSpentMicrousd: Int64 = 0
    private(set) var burnSeries: [BurnPoint] = []
    /// Same meaning as `ExceptionQueueStore.deauthorized`: the relay rejected
    /// this device's token, so the pairing is gone rather than the network.
    private(set) var deauthorized = false

    var othersSpent: Double { othersSpentMicrousd.usd }
    var hasSnapshot: Bool { aggregates != nil }

    func load(using client: APIClient) async {
        if aggregates == nil, phase != .loaded { phase = .loading }
        do {
            let snapshot = try await client.money()
            aggregates = snapshot.aggregates
            savings = snapshot.savings
            agents = snapshot.agents
            agentsTruncated = snapshot.agentsTruncated
            othersSpentMicrousd = snapshot.othersSpentMicrousd
            burnSeries = snapshot.burnSeries
            phase = .loaded
        } catch APIClient.ClientError.http(401) {
            deauthorized = true
        } catch {
            if aggregates == nil {
                phase = .failed(error.localizedDescription)
            }
            // else: keep showing the last-known-good snapshot.
        }
    }
}
