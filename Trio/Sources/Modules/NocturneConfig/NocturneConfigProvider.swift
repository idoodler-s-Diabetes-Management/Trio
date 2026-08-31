import Combine
import Foundation

extension NocturneConfig {
    final class Provider: BaseProvider, NocturneConfigProvider {
        func checkConnection(url: URL, secret: String?) -> AnyPublisher<Void, Error> {
            Future { promise in
                Task {
                    do {
                        try await NocturneAPI(url: url, secret: secret).checkConnection()
                        promise(.success(()))
                    } catch {
                        promise(.failure(error))
                    }
                }
            }.eraseToAnyPublisher()
        }
    }
}
