# Trading Mechanics

## Overview

WallyBaba implements sophisticated trading mechanics designed to ensure:
- Market stability
- Fair price discovery
- Protection against manipulation
- Optimal liquidity utilization

## Trading Parameters

### Transaction Limits
- Minimum Trade: 0.001% of pool
- Maximum Trade: 1% of pool
- Cooldown Period: 30 minutes for large trades

### Price Impact Protection
- Slippage Tolerance: 1-3%
- Price Impact Warning: >1%
- Automatic Rejection: >5%

## Market Making Mechanics

### Liquidity Pools
- Primary Pool: Raydium
- Secondary Pools: Jupiter, Orca
- Cross-pool arbitrage enabled

### Price Calculation
```solidity
price = (token_reserve_x * constant_product) / token_reserve_y
```

### Slippage Protection
```solidity
max_slippage = base_slippage + (trade_size / pool_size * slippage_multiplier)
```

## Trading Features

### Limit Orders
- Supported through Raydium
- Maximum duration: 7 days
- Cancellation fee: 0.1%

### Stop Loss
- Available for all trades
- Minimum distance: 5%
- Maximum duration: 30 days

### Dollar Cost Averaging (DCA)
- Minimum period: 1 day
- Maximum period: 90 days
- Frequency options: Daily, Weekly, Monthly

## Trading Restrictions

### Time-based Restrictions
- Market hours: 24/7
- Maintenance windows: Announced 24h in advance
- Emergency pauses: By DAO vote only

### Volume-based Restrictions
- Per-wallet daily limit: 5% of pool
- Global daily limit: 20% of pool
- Adjustable through governance

## Trading Interface

### Official Platforms
- [WallyBaba DEX](https://dex.wallybaba.io)
- [Raydium](https://raydium.io)
- [Jupiter](https://jup.ag)

### API Access
- Public API available
- Rate limits apply
- Documentation: [API Docs](../guides/api.md)

## Market Protection

### Circuit Breakers
- 15% price movement in 5 minutes
- 30% price movement in 1 hour
- 50% price movement in 24 hours

### Anti-manipulation
- Wash trading detection
- Front-running protection
- Sandwich attack prevention

## Related Documentation
- [Fee Structure](fees.md)
- [Anti-Whale Mechanisms](anti-whale.md)
- [Emergency Controls](../security/emergency-controls.md) 