// The Swift Programming Language
// https://docs.swift.org/swift-book

import StoreKit

public typealias Transaction = StoreKit.Transaction
public typealias RenewalInfo = StoreKit.Product.SubscriptionInfo.RenewalInfo
public typealias RenewalState = StoreKit.Product.SubscriptionInfo.RenewalState

public enum StoreError: Error {
    case failedVerification
}

public class EasyStoreKit: ObservableObject {
    
    @Published public private(set) var subscriptions: [Product] = []
    @Published public private(set) var purchasedSubscriptions: [Product] = []
    @Published public private(set) var subscriptionGroupStatus: RenewalState?
    
    var updateListenerTask: Task<Void, Error>? = nil
    
    public init() {
        //Start a transaction listener as close to app launch as possible so you don't miss any transactions.
        updateListenerTask = listenForTransactions()
        Task {
            //Deliver products that the customer purchases.
            await updateCustomerProductStatus()
        }
    }
    
    deinit {
        updateListenerTask?.cancel()
    }
    
    func listenForTransactions() -> Task<Void, Error> {
        return Task.detached { [weak self] in
            //Iterate through any transactions that don't come from a direct call to `purchase()`.
            for await result in Transaction.updates {
                print("TRANSACTION RESULT: \(result)")
                do {
                    guard let self = self else { return }
                    let transaction = try self.checkVerified(result)
                    //Deliver products to the user.
                    await self.updateCustomerProductStatus()
                    //Always finish a transaction.
                    await transaction.finish()
                    print("⚠️ Transaction update processed: \(transaction)")
                } catch {
                    //StoreKit has a transaction that fails verification. Don't deliver content to the user.
                    print("Transaction failed verification")
                }
            }
        }
    }
    
    @MainActor
    public func requestProducts(for subscriptionsIdentifiers: [String]) async {
        do {
            // Запрашиваем продукты из App Store, используя идентификаторы из массива subscriptionProductIDs
            let storeProducts = try await Product.products(for: subscriptionsIdentifiers)
            // Фильтруем продукты по их типу
            subscriptions = storeProducts.filter { $0.type == .autoRenewable }
            // Сортируем продукты по цене, от низкой к высокой, для обновления магазина
            subscriptions = sortByPrice(subscriptions)
        } catch {
            print("Failed product request from the App Store server: \(error)")
        }
    }
    
    public func purchase(_ product: Product) async throws -> Transaction? {
        //Begin purchasing the `Product` the user selects.
        let result = try await product.purchase()
        switch result {
        case .success(let verificationResult):
            //Check whether the transaction is verified. If it isn't,
            //this function rethrows the verification error.
            let transaction = try checkVerified(verificationResult)
            //The transaction is verified. Deliver content to the user.
            await updateCustomerProductStatus()
            //Always finish a transaction.
            await transaction.finish()
            return transaction
        case .userCancelled, .pending:
            return nil
        @unknown default:
            return nil
        }
    }
    
    public func isPurchased(_ product: Product) async throws -> Bool {
        //Determine whether the user purchases a given product.
        switch product.type {
        case .autoRenewable:
            return purchasedSubscriptions.contains(product)
        default:
            return false
        }
    }
    
    public func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        //Check whether the JWS passes StoreKit verification.
        switch result {
        case .unverified:
            //StoreKit parses the JWS, but it fails verification.
            throw StoreError.failedVerification
        case .verified(let safe):
            //The result is verified. Return the unwrapped value.
            return safe
        }
    }
    
    @MainActor
    public func updateCustomerProductStatus() async {
        var purchasedSubscriptions: [Product] = []
        //Iterate through all of the user's purchased products.
        for await result in Transaction.currentEntitlements {
            do {
                //Check whether the transaction is verified. If it isn’t, catch `failedVerification` error.
                let transaction = try checkVerified(result)
                
                //Check the `productType` of the transaction and get the corresponding product from the store.
                switch transaction.productType {
                case .autoRenewable:
                    if let subscription = subscriptions.first(where: { $0.id == transaction.productID }) {
                        purchasedSubscriptions.append(subscription)
                    }
                    print("TRANSACTION: \(transaction)")
                default:
                    break
                }
            } catch {
                print()
            }
        }
        //Update the store information with auto-renewable subscription products.
        self.purchasedSubscriptions = purchasedSubscriptions
        
        subscriptionGroupStatus = try? await subscriptions.first?.subscription?.status.first?.state
    }
    
    public func sortByPrice(_ products: [Product]) -> [Product] {
        products.sorted(by: { return $0.price < $1.price })
    }
}
