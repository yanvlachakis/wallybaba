# Anti-Whale Mechanisms

WallyBaba implements sophisticated anti-whale mechanisms designed to protect regular investors while maintaining market liquidity and trading freedom. These mechanisms are carefully balanced to prevent market manipulation without restricting normal trading activity.

## Key Points for Investors

### 💡 Your Funds Are Not Locked
- Regular investors (holding < 0.2% of pool) can trade freely
- Standard 2% fee applies to normal transactions
- No cooldown periods for regular-sized trades
- Full access to all trading features

### 🐋 Progressive Restrictions

#### Transaction Size Limits
| Trade Size (% of Pool) | Fee | Cooldown | Max Daily Volume |
|------------------------|-----|----------|------------------|
| < 0.2% | 2% | None | No limit |
| 0.2% - 0.5% | 3% | 5 minutes | 5% of pool |
| 0.5% - 1.0% | 4% | 15 minutes | 3% of pool |
| > 1.0% | 5% | 30 minutes | 1% of pool |

### 📊 Impact Analysis
For perspective, with a $10M liquidity pool:
- Regular traders ($20k or less) = No restrictions
- Medium traders ($20k-$50k) = Minor fees
- Large traders ($50k-$100k) = Moderate restrictions
- Whale traders ($100k+) = Full restrictions

## Time-Based Protections

### Launch Phase (Days 1-60)
- Maximum sell order: 0.25% of liquidity
- Enhanced cooldown periods
- Stricter volume limits

### Growth Phase (Days 61-180)
- Maximum sell order: 0.5% of liquidity
- Standard cooldown periods
- Normal volume limits

### Mature Phase (180+ days)
- Maximum sell order: 0.75% of liquidity
- Reduced cooldown periods
- Relaxed volume limits

## Dynamic Adjustments

### Market Conditions
The system automatically adjusts restrictions based on:
- Current liquidity levels
- 24-hour trading volume
- Price volatility
- Market depth

### Emergency Controls
- Automatic circuit breakers for extreme volatility
- Community governance can adjust parameters
- Emergency pause for severe market conditions

## Benefits for Regular Investors

### 🛡️ Protection Features
1. **Price Stability**
   - Prevents sudden large dumps
   - Maintains healthy price discovery
   - Reduces manipulation potential

2. **Liquidity Protection**
   - Ensures available trading liquidity
   - Prevents liquidity drainage
   - Maintains market efficiency

3. **Fair Trading Environment**
   - Equal access for all traders
   - Transparent restrictions
   - Predictable trading conditions

## How to Trade Efficiently

### Best Practices
1. **Regular Trading**
   - Keep transactions under 0.2% of pool size
   - Trade during normal market hours
   - Monitor market conditions

2. **Larger Positions**
   - Split large trades into smaller ones
   - Consider time intervals between trades
   - Watch liquidity levels

3. **Portfolio Management**
   - Diversify entry/exit points
   - Use limit orders when possible
   - Monitor daily volume limits

## FAQ

### Common Questions

**Q: Are my tokens locked?**
A: No. Regular traders (< 0.2% of pool) can trade freely with minimal restrictions.

**Q: How do I know my trade size category?**
A: The interface shows your trade size relative to pool size and applicable restrictions.

**Q: Can restrictions change?**
A: Yes, through governance votes or automatic adjustments based on market conditions.

**Q: What happens if I exceed limits?**
A: Transactions will be rejected by the smart contract until conditions are met.

## Technical Implementation

```rust
// Example of trade validation logic
pub fn validate_trade(
    amount: u64,
    pool_size: u64,
    last_trade_time: i64
) -> Result<()> {
    let trade_percentage = (amount * 100) / pool_size;
    
    match trade_percentage {
        0..=20 => Ok(()), // Regular trades pass
        21..=50 => validate_medium_trade(last_trade_time),
        51..=100 => validate_large_trade(last_trade_time),
        _ => validate_whale_trade(last_trade_time)
    }
}
```

## Additional Resources
- [Trading Guide](../guides/trading.md)
- [Market Metrics](../guides/market-metrics.md)
- [Governance Controls](../governance/controls.md) 