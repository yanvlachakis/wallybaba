# WallyBaba Trading Protection Mechanisms

## Overview

WallyBaba implements a comprehensive suite of trading protection mechanisms to ensure fair trading, prevent market manipulation, and protect investors. These mechanisms are designed to be adaptive and responsive to market conditions while maintaining liquidity efficiency.

## Core Protection Features

### 1. Progressive Penalty System
- Replaces instant bans with graduated restrictions
- Four penalty tiers with increasing cooldown periods:
  - Tier 1: 2x base cooldown
  - Tier 2: 4x base cooldown
  - Tier 3: 8x base cooldown
  - Tier 4: 24-hour cooldown
- Violations tracked per wallet with automatic tier progression

### 2. Liquidity Protection
- Delayed withdrawals for large liquidity providers:
  - Regular withdrawals: 24-hour delay
  - Large withdrawals (>5%): 7-day delay
- Minimum liquidity ratio requirements
- Anti-sniping detection for new liquidity
- Holding period incentives

### 3. Multi-Oracle Price Validation
- Weighted average from multiple price feeds
- Maximum 5% deviation tolerance
- 5-minute staleness check
- Required for large transactions
- Dynamic price impact thresholds

### 4. Market Health Monitoring
- Real-time liquidity health scoring (0-100)
- Components:
  - Liquidity ratio (40% weight)
  - 24h volume (30% weight)
  - Volatility index (30% weight)
- Automatic trading restrictions when health score < 50

### 5. Dynamic Circuit Breakers
- Volatility-based triggers
- Adaptive pause durations:
  - 30 minutes for moderate events
  - 2 hours for severe events
- Market stabilization checks before resumption
- Community governance oversight

### 6. Fee Structure and Refunds
- Progressive fee tiers based on trade size
- Long-term LP fee refund program:
  - 30+ days: 25% fee refund
  - 90+ days: 50% fee refund
  - 180+ days: 75% fee refund
- Minimum LP amount requirements for refunds

### 7. Emergency Controls
- Multi-signature requirement for critical actions
- Community timelock for emergency measures
- Graduated emergency powers based on market conditions
- Transparent incident reporting

## Trading Restrictions

### Launch Phase (0-75 days)
- Maximum trade: 0.25% of liquidity
- Enhanced monitoring and restrictions
- Mandatory cooldown periods

### Growth Phase (75-150 days)
- Progressive increase in limits
- Dynamic adjustment based on market health
- Reduced cooldown periods

### Mature Phase (150+ days)
- Standard trading limits
- Focus on manipulation prevention
- Market-driven restrictions

## Implementation Details

### Suspicious Pattern Detection
```rust
fn is_suspicious_pattern(amount: u64, is_sell: bool, state: &TokenState) -> bool {
    // Large buy near launch
    if !is_sell && current_time - state.launch_time < 3600 && amount > state.total_liquidity / 100 {
        return true;
    }
    
    // Quick sell after buy
    if is_sell && current_time - state.last_transaction_time < 60 {
        return true;
    }
    
    // Multiple trades in short time
    if state.trade_count_in_block > 2 {
        return true;
    }
    
    false
}
```

### Market Health Calculation
```rust
fn calculate_health_score(
    liquidity: u64,
    total_locked: u64,
    volume_24h: u64,
    volatility: u64
) -> Result<u8> {
    let mut score = 100u8;
    
    // Liquidity ratio impact (40% weight)
    let liquidity_ratio = (liquidity * 100) / total_locked;
    if liquidity_ratio < 50 {
        score = score.saturating_sub(40);
    } else if liquidity_ratio < 75 {
        score = score.saturating_sub(20);
    }
    
    // Volume impact (30% weight)
    let volume_ratio = (volume_24h * 100) / total_locked;
    if volume_ratio < 5 {
        score = score.saturating_sub(30);
    } else if volume_ratio < 10 {
        score = score.saturating_sub(15);
    }
    
    // Volatility impact (30% weight)
    if volatility > 20 {
        score = score.saturating_sub(30);
    } else if volatility > 10 {
        score = score.saturating_sub(15);
    }
    
    Ok(score)
}
```

## Best Practices for Traders

1. **Regular Trading**
   - Stay within recommended trade sizes
   - Observe cooldown periods
   - Monitor market health indicators

2. **Liquidity Provision**
   - Plan withdrawals in advance
   - Maintain minimum holding periods
   - Understand fee refund requirements

3. **Emergency Situations**
   - Monitor official announcements
   - Follow emergency procedures
   - Participate in governance decisions

## Governance and Updates

- Community voting on parameter adjustments
- Transparent update process
- Regular security audits
- Incident response procedures

## Additional Resources

- [Trading Guidelines](../guides/trading.md)
- [Governance Documentation](../governance/README.md)
- [Market Metrics Dashboard](https://metrics.wallybaba.com)
- [Security Incident Reports](https://security.wallybaba.com) 