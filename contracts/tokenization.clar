;; PropertyToken 
;; A smart contract for tokenizing intellectual property assets with Escrow Mechanism

(define-fungible-token creative-tokens)

;; Storage for contract metadata and asset details
(define-data-var protocol-manager principal tx-sender)
(define-data-var property-count uint u0)
(define-data-var current-level uint u0)

;; Storing asset details with enhanced ownership tracking
(define-map property-catalog 
    {property-id: uint}
    {
        rights-holder: principal,
        base-value: uint,
        market-value: uint,
        token-supply: uint,
        stakeholders: (list 10 principal),
        is-transferable: bool
    }
)

;; Stakeholder tracking
(define-map ownership-registry 
    {property-id: uint, stakeholder: principal}
    uint
)

;; Escrow tracking for licensing agreements
(define-map usage-contracts
    {
        property-id: uint,
        consumer: principal,
        provider: principal
    }
    {
        contract-value: uint,
        fulfillment-status: bool,
        termination-level: uint,
        provider: principal
    }
)

;; Function to update current level
(define-public (increment-level)
    (begin
        (var-set current-level (+ (var-get current-level) u1))
        (ok (var-get current-level))
    )
)

;; Input validation functions
(define-private (is-nonzero (value uint))
    (> value u0)
)

;; Mint tokens for property ownership
(define-public (register-creative-property 
    (property-id uint) 
    (base-value uint)
    (token-supply uint)
)
    (begin
        ;; Validate inputs
        (asserts! (is-nonzero property-id) (err u400))
        (asserts! (is-nonzero base-value) (err u400))
        (asserts! (is-nonzero token-supply) (err u400))
        
        ;; Increment property count
        (var-set property-count (+ (var-get property-count) u1))
        
        ;; Store property details
        (map-set property-catalog 
            {property-id: property-id}
            {
                rights-holder: tx-sender,
                base-value: base-value,
                market-value: base-value,
                token-supply: token-supply,
                stakeholders: (list tx-sender),
                is-transferable: true
            }
        )
        
        ;; Mint tokens and track initial holder balance
        (match (ft-mint? creative-tokens token-supply tx-sender)
            success 
            (begin
                (map-set ownership-registry 
                    {property-id: property-id, stakeholder: tx-sender} 
                    token-supply
                )
                (ok success)
            )
            error (err u500)
        )
    )
)

;; Transfer fractional property tokens
(define-public (transfer-ownership 
    (property-id uint)
    (amount uint)
    (recipient principal)
)
    (let 
        (
            (property (unwrap! (map-get? property-catalog {property-id: property-id}) (err u404)))
            (sender-balance (default-to u0 (map-get? ownership-registry {property-id: property-id, stakeholder: tx-sender})))
            (recipient-balance (default-to u0 (map-get? ownership-registry {property-id: property-id, stakeholder: recipient})))
            (recipient-tokens (map-get? ownership-registry {property-id: property-id, stakeholder: recipient}))
        )
        ;; Validate transfer conditions
        (asserts! (is-nonzero amount) (err u400))
        (asserts! (<= amount sender-balance) (err u403))
        (asserts! (get is-transferable property) (err u403))
        
        ;; Perform token transfer
        (match (ft-transfer? creative-tokens amount tx-sender recipient)
            success 
            (begin
                ;; Update sender and recipient balances
                (map-set ownership-registry 
                    {property-id: property-id, stakeholder: tx-sender} 
                    (- sender-balance amount)
                )
                (map-set ownership-registry 
                    {property-id: property-id, stakeholder: recipient} 
                    (+ (default-to u0 recipient-tokens) amount)
                )
                
                ;; Update stakeholders list if needed
                (if (is-some recipient-tokens)
                    true
                    (map-set property-catalog 
                        {property-id: property-id}
                        (merge property {
                            stakeholders: (unwrap-panic 
                                (as-max-len? 
                                    (append (get stakeholders property) recipient) 
                                    u10
                                ))
                        })
                    )
                )
                
                (ok success)
            )
            error (err u500)
        )
    )
)

;; Update property value
(define-public (update-property-value 
    (property-id uint)
    (new-value uint)
)
    (let 
        (
            (property (unwrap! (map-get? property-catalog {property-id: property-id}) (err u404)))
        )
        ;; Validate and restrict valuation updates
        (asserts! (is-nonzero new-value) (err u400))
        (asserts! 
            (or 
                (is-eq tx-sender (get rights-holder property))
                (is-eq tx-sender (var-get protocol-manager))
            ) 
            (err u403)
        )
        
        ;; Update property value
        (map-set property-catalog 
            {property-id: property-id}
            (merge property {market-value: new-value})
        )
        
        (ok new-value)
    )
)

;; Initiate usage contract escrow
(define-public (create-usage-contract
    (property-id uint)
    (consumer principal)
    (contract-value uint)
    (usage-duration uint)
)
    (let 
        (
            (property (unwrap! (map-get? property-catalog {property-id: property-id}) (err u404)))
            (property-owner (get rights-holder property))
            (current-position (var-get current-level))
        )
        ;; Validate inputs
        (asserts! (is-nonzero contract-value) (err u400))
        (asserts! (is-eq tx-sender property-owner) (err u403))
        (asserts! (not (is-eq consumer property-owner)) (err u400))
        
        ;; Create contract entry
        (map-set usage-contracts
            {
                property-id: property-id,
                consumer: consumer,
                provider: property-owner
            }
            {
                contract-value: contract-value,
                fulfillment-status: false,
                termination-level: (+ current-position usage-duration),
                provider: property-owner
            }
        )
        
        (ok true)
    )
)

;; Deposit contract payment into escrow
(define-public (submit-contract-payment
    (property-id uint)
    (consumer principal)
)
    (let 
        (
            (contract-details (unwrap! 
                (map-get? usage-contracts 
                    {
                        property-id: property-id, 
                        consumer: consumer,
                        provider: tx-sender
                    }
                ) 
                (err u404)
            ))
            (payment (get contract-value contract-details))
            (current-position (var-get current-level))
        )
        ;; Validate deposit
        (asserts! (is-eq tx-sender consumer) (err u403))
        (asserts! (< current-position (get termination-level contract-details)) (err u400))
        
        ;; Transfer payment to contract
        (match (stx-transfer? payment consumer (as-contract tx-sender))
            success 
            (ok true)
            error (err u500)
        )
    )
)

;; Confirm contract fulfillment
(define-public (confirm-contract-fulfillment
    (property-id uint)
    (consumer principal)
)
    (let 
        (
            (contract-details (unwrap! 
                (map-get? usage-contracts 
                    {
                        property-id: property-id, 
                        consumer: consumer,
                        provider: tx-sender
                    }
                ) 
                (err u404)
            ))
            (payment (get contract-value contract-details))
        )
        ;; Validate confirmation
        (asserts! (is-eq tx-sender (get provider contract-details)) (err u403))
        
        ;; Mark contract as fulfilled and release funds
        (map-set usage-contracts
            {
                property-id: property-id,
                consumer: consumer,
                provider: tx-sender
            }
            (merge contract-details {fulfillment-status: true})
        )
        
        ;; Release funds to provider
        (as-contract 
            (stx-transfer? payment (as-contract tx-sender) tx-sender)
        )
    )
)

;; Refund mechanism for unfulfilled contracts
(define-public (request-contract-refund
    (property-id uint)
    (consumer principal)
)
    (let 
        (
            (contract-details (unwrap! 
                (map-get? usage-contracts 
                    {
                        property-id: property-id, 
                        consumer: consumer,
                        provider: tx-sender
                    }
                ) 
                (err u404)
            ))
            (payment (get contract-value contract-details))
            (current-position (var-get current-level))
        )
        ;; Validate refund conditions
        (asserts! (>= current-position (get termination-level contract-details)) (err u400))
        (asserts! (not (get fulfillment-status contract-details)) (err u400))
        
        ;; Refund to consumer
        (as-contract 
            (stx-transfer? payment (as-contract tx-sender) consumer)
        )
    )
)

;; Get token ownership amount
(define-read-only (get-ownership-amount 
    (property-id uint)
    (stakeholder principal)
)
    (default-to u0 (map-get? ownership-registry {property-id: property-id, stakeholder: stakeholder}))
)

;; Read property details
(define-read-only (get-property-details (property-id uint))
    (map-get? property-catalog {property-id: property-id})
)

;; Read contract details
(define-read-only (get-contract-details 
    (property-id uint)
    (consumer principal)
    (provider principal)
)
    (map-get? usage-contracts 
        {
            property-id: property-id, 
            consumer: consumer,
            provider: provider
        }
    )
)