use anchor_lang::prelude::*;
use anchor_spl::token::{self, Mint, Token, TokenAccount, MintTo};
use anchor_spl::dex::serum_dex::state::MarketState;  // For Raydium integration

declare_id!("YOUR_WALLET_PUBLIC_KEY_HERE");

#[program]
pub mod wallybaba {
    use super::*;

    pub fn initialize(ctx: Context<Initialize>, initial_supply: u64, branding: Option<BrandingMetadata>) -> Result<()> {
        require!(initial_supply > 0, ErrorCode::InvalidSupply);
        require!(initial_supply <= u64::MAX / 100, ErrorCode::SupplyTooLarge);  // Prevent overflow

        let mint = &ctx.accounts.mint;
        let authority = &ctx.accounts.authority;
        let token_program = &ctx.accounts.token_program;
        let liquidity_pool = &ctx.accounts.liquidity_pool;
        let team_account = &ctx.accounts.team_account;

        // Initial supply with anti-bot measures
        let team_allocation = initial_supply / 100;  // 1% to team
        let liquidity_allocation = initial_supply - team_allocation;  // 99% to liquidity
        
        // Initialize trading limits
        let state = &mut ctx.accounts.state;
        state.max_transaction_amount = initial_supply / 100;  // 1% max transaction
        state.max_wallet_amount = initial_supply / 20;   // 5% max wallet
        state.trading_active = false;  // Requires manual activation
        state.authority = *authority.key;
        state.paused = false;  // New emergency pause feature
        state.last_transaction_time = Clock::get()?.unix_timestamp;  // Rate limiting
        state.transaction_count = 0;  // Transaction counting for rate limiting
        state.launch_time = Clock::get()?.unix_timestamp;
        state.trading_enabled = false;
        state.sniper_tax_end_time = state.launch_time + 86400; // 24 hours
        state.blacklisted_addresses = Vec::new();
        state.last_trade_block = 0;
        state.trade_count_in_block = 0;
        state.suspicious_patterns = 0;

        // Mint liquidity supply with checks
        let cpi_accounts = MintTo {
            mint: mint.to_account_info(),
            to: liquidity_pool.to_account_info(),
            authority: authority.to_account_info(),
        };
        let cpi_ctx = CpiContext::new(token_program.to_account_info(), cpi_accounts);
        token::mint_to(cpi_ctx, liquidity_allocation)?;

        // Mint team allocation with checks
        let cpi_accounts = MintTo {
            mint: mint.to_account_info(),
            to: team_account.to_account_info(),
            authority: authority.to_account_info(),
        };
        let cpi_ctx = CpiContext::new(token_program.to_account_info(), cpi_accounts);
        token::mint_to(cpi_ctx, team_allocation)?;

        if let Some(metadata) = branding {
            state.initialize_branding(metadata)?;
        }

        // Emit initialization event with branding
        emit!(TokenInitializedEvent {
            timestamp: Clock::get()?.unix_timestamp,
            initial_supply,
            liquidity_allocation,
            team_allocation,
            branding: state.branding.clone(),
        });

        Ok(())
    }

    pub fn pause_trading(ctx: Context<PauseTrading>) -> Result<()> {
        let state = &mut ctx.accounts.state;
        require!(ctx.accounts.authority.key() == &state.authority, ErrorCode::Unauthorized);
        
        state.paused = true;
        emit!(TradingPausedEvent {
            timestamp: Clock::get()?.unix_timestamp,
        });
        Ok(())
    }

    pub fn resume_trading(ctx: Context<PauseTrading>) -> Result<()> {
        let state = &mut ctx.accounts.state;
        require!(ctx.accounts.authority.key() == &state.authority, ErrorCode::Unauthorized);
        
        state.paused = false;
        emit!(TradingResumedEvent {
            timestamp: Clock::get()?.unix_timestamp,
        });
        Ok(())
    }

    pub fn activate_trading(ctx: Context<ActivateTrading>) -> Result<()> {
        let state = &mut ctx.accounts.state;
        require!(ctx.accounts.authority.key() == &state.authority, ErrorCode::Unauthorized);
        state.trading_active = true;
        Ok(())
    }

    pub fn update_limits(
        ctx: Context<UpdateLimits>,
        max_tx: Option<u64>,
        max_wallet: Option<u64>
    ) -> Result<()> {
        let state = &mut ctx.accounts.state;
        require!(ctx.accounts.authority.key() == &state.authority, ErrorCode::Unauthorized);
        
        if let Some(max_tx_amount) = max_tx {
            state.max_transaction_amount = max_tx_amount;
        }
        if let Some(max_wallet_amount) = max_wallet {
            state.max_wallet_amount = max_wallet_amount;
        }
        Ok(())
    }

    pub fn update_price_data(
        ctx: Context<UpdatePriceData>,
        new_price: u64,
        timestamp: i64
    ) -> Result<()> {
        let state = &mut ctx.accounts.state;
        require!(ctx.accounts.authority.key() == &state.authority, ErrorCode::Unauthorized);
        
        // Check for excessive price impact
        if state.last_price > 0 {
            let price_change = if new_price > state.last_price {
                ((new_price - state.last_price) * 100) / state.last_price
            } else {
                ((state.last_price - new_price) * 100) / state.last_price
            };
            
            require!(price_change <= state.price_impact_limit, ErrorCode::ExcessivePriceImpact);
        }
        
        state.last_price = new_price;
        state.last_price_timestamp = timestamp;
        Ok(())
    }

    pub fn update_protection_params(
        ctx: Context<UpdateProtection>,
        impact_limit: Option<u64>,
        cooldown: Option<u64>
    ) -> Result<()> {
        let state = &mut ctx.accounts.state;
        require!(ctx.accounts.authority.key() == &state.authority, ErrorCode::Unauthorized);
        
        if let Some(impact) = impact_limit {
            require!(impact <= 20, ErrorCode::InvalidParameter); // Max 20% impact
            state.price_impact_limit = impact;
        }
        
        if let Some(cd) = cooldown {
            state.cooldown_period = cd;
        }
        
        Ok(())
    }

    pub fn calculate_fee(ctx: Context<CalculateFee>, trade_size: u64) -> Result<u64> {
        let state = &ctx.accounts.state;
        let liquidity = state.total_liquidity;
        
        // Calculate trade percentage of liquidity
        let trade_percent = (trade_size * 100) / liquidity;
        
        // Progressive fee structure
        let fee = match trade_percent {
            0..=20 => 200,  // 2% base fee
            21..=50 => 300, // 3% fee
            51..=100 => 400, // 4% fee
            _ => 500,       // 5% fee
        };
        
        Ok(fee)
    }

    pub fn validate_trade(ctx: Context<ValidateTrade>, amount: u64, is_sell: bool) -> Result<()> {
        let state = &mut ctx.accounts.state;
        let wallet = ctx.accounts.trader.key();
        
        // Anti-snipe validation with progressive penalties
        state.validate_anti_snipe(&wallet, amount)?;
        
        // Check for penalty tier cooldowns
        if let Some(tier) = state.penalty_tiers.iter().find(|t| t.wallet == *wallet) {
            let current_time = Clock::get()?.unix_timestamp;
            let required_cooldown = state.cooldown_period * tier.cooldown_multiplier;
            require!(
                current_time - tier.last_violation_time >= required_cooldown as i64,
                ErrorCode::CooldownNotElapsed
            );
        }
        
        // Adaptive rate limiting
        state.validate_adaptive_rate_limit(amount)?;
        
        // Enhanced flash loan protection with multi-oracle validation
        state.validate_flash_loan_protection(&wallet, amount)?;
        state.validate_oracle_price(state.last_price)?;
        
        let current_time = Clock::get()?.unix_timestamp;
        let time_since_launch = current_time - state.launch_time;
        
        // Update historical balances with improved tracking
        if let Some(history) = state.historical_balances.iter_mut().find(|h| h.wallet == *wallet) {
            history.balances.push((current_time, amount));
            if history.balances.len() > 10 {
                history.balances.remove(0);
            }
        } else {
            state.historical_balances.push(HistoricalBalance {
                wallet: *wallet,
                balances: vec![(current_time, amount)],
            });
        }
        
        // Volume tracking with enhanced checks
        let current_block = Clock::get()?.slot;
        if state.volume_per_block.len() >= 100 {
            state.volume_per_block.remove(0);
        }
        state.volume_per_block.push(amount);
        
        // Update wallet cooldowns with progressive penalties
        if let Some(cooldown) = state.wallet_cooldowns.iter_mut().find(|c| c.wallet == *wallet) {
            cooldown.total_trades += 1;
            cooldown.last_trade_time = current_time;
            
            // Check for suspicious patterns
            if is_suspicious_pattern(amount, is_sell, state) {
                state.update_penalty_tier(&wallet)?;
            }
        } else {
            state.wallet_cooldowns.push(WalletCooldown {
                wallet: *wallet,
                last_trade_time: current_time,
                total_trades: 1,
                similar_wallets: Vec::new(),
            });
        }
        
        // Enhanced circuit breakers with governance
        state.validate_circuit_breakers(state.last_price)?;
        
        if is_sell {
            // Process LP withdrawal requests
            if let Some(withdrawal) = state.lp_withdrawal_delays.iter().find(|w| w.wallet == *wallet) {
                require!(
                    current_time >= withdrawal.unlock_time,
                    ErrorCode::WithdrawalLocked
                );
            }
            
            // Calculate and process fee refunds for long-term LPs
            let fee_refund = state.calculate_fee_refund(&wallet)?;
            if fee_refund > 0 {
                process_fee_refund(&wallet, fee_refund)?;
            }
            
            // Graduated restrictions with dynamic adjustments
            let max_sell_percentage = if time_since_launch < 6_480_000 { // First 75 days
                25 // 0.25%
            } else if time_since_launch < 12_960_000 { // 75-150 days
                let progress = (time_since_launch - 6_480_000) as f64 / (6_480_000 as f64);
                (25.0 + (progress * 25.0)) as u64
            } else if time_since_launch < 19_440_000 { // 150-225 days
                let progress = (time_since_launch - 12_960_000) as f64 / (6_480_000 as f64);
                (50.0 + (progress * 25.0)) as u64
            } else {
                75 // 0.75%
            };
            
            require!(
                amount <= state.total_liquidity * max_sell_percentage / 10000,
                ErrorCode::ExceedsTradeLimit
            );
            
            // Process buybacks if conditions are met
            state.process_buyback()?;
        }
        
        Ok(())
    }

    pub fn update_branding(ctx: Context<UpdateBranding>, metadata: BrandingMetadata) -> Result<()> {
        let state = &mut ctx.accounts.state;
        state.update_branding(metadata)?;
        
        emit!(BrandingUpdatedEvent {
            timestamp: Clock::get()?.unix_timestamp,
            metadata: metadata.clone(),
        });
        
        Ok(())
    }

    pub fn add_liquidity(ctx: Context<AddLiquidity>, amount: u64) -> Result<()> {
        let state = &mut ctx.accounts.state;
        let wallet = ctx.accounts.liquidity_provider.key();
        let current_time = Clock::get()?.unix_timestamp;
        
        // Check liquidity hold time
        if let Some(hold_time) = state.liquidity_hold_times.iter().find(|h| h.wallet == *wallet) {
            require!(
                current_time - hold_time.first_hold_time >= 10 * 6, // Approximately 10 blocks
                ErrorCode::LiquiditySnipingDetected
            );
        } else {
            state.liquidity_hold_times.push(LiquidityHoldTime {
                wallet: *wallet,
                first_hold_time: current_time,
                amount,
            });
        }
        
        // ... rest of liquidity addition logic ...
        
        Ok(())
    }
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct BrandingMetadata {
    pub name: String,
    pub symbol: String,
    pub description: String,
    pub logo_uri: String,
    pub images: Images,
    pub colors: Colors,
    pub official_links: OfficialLinks,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct Images {
    pub token: String,      // 512x512 DEX listing
    pub twitter: String,    // 400x400 Twitter
    pub telegram: String,   // 640x640 Telegram
    pub discord: String,    // 256x256 Discord
    pub favicon: String,    // 32x32 Website
    pub high_res: String,   // 2048x2048 Marketing
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct Colors {
    pub primary: String,    // Dark Brown
    pub secondary: String,  // Solana Green
    pub accent: String,     // Solana Purple
    pub background: String, // White/Transparent
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct OfficialLinks {
    pub website: String,
    pub twitter: String,
    pub telegram: String,
    pub discord: String,
}

#[account]
pub struct TokenState {
    pub authority: Pubkey,
    pub trading_active: bool,
    pub paused: bool,  // New emergency pause state
    pub max_transaction_amount: u64,
    pub max_wallet_amount: u64,
    pub last_transaction_time: i64,  // For rate limiting
    pub transaction_count: u64,      // For rate limiting
    pub last_price: u64,
    pub last_price_timestamp: i64,
    pub price_impact_limit: u64,
    pub cooldown_period: u64,
    pub last_large_trade_timestamp: i64,
    pub total_liquidity: u64,
    pub circulating_supply: u64,
    pub launch_time: i64,
    pub trading_enabled: bool,
    pub sniper_tax_end_time: i64,
    pub blacklisted_addresses: Vec<Pubkey>,
    pub last_trade_block: u64,
    pub trade_count_in_block: u64,
    pub suspicious_patterns: u64,
    pub progressive_fees_enabled: bool,
    pub max_sell_percent: u64,  // Dynamic max sell percentage
    pub total_daily_volume: u64,
    pub wallet_daily_volume: u64,
    pub last_volume_reset: i64,
    pub branding: Option<BrandingMetadata>,
    pub historical_volatility: u64,
    pub volume_per_block: Vec<u64>,
    pub wallet_cooldowns: Vec<WalletCooldown>,
    pub liquidity_hold_times: Vec<LiquidityHoldTime>,
    pub historical_balances: Vec<HistoricalBalance>,
    pub pause_duration: u64,
    pub last_buyback_time: i64,
    pub daily_fee_revenue: u64,
    pub penalty_tiers: Vec<PenaltyTier>,
    pub lp_withdrawal_delays: Vec<LPWithdrawal>,
    pub oracle_price_feeds: Vec<OraclePriceFeed>,
    pub governance_settings: GovernanceSettings,
    pub timelock_duration: i64,
    pub fee_refund_schedule: Vec<FeeRefund>,
    pub buyback_settings: BuybackSettings,
}

impl TokenState {
    pub fn initialize_branding(&mut self, metadata: BrandingMetadata) -> Result<()> {
        self.branding = Some(metadata);
        Ok(())
    }

    pub fn update_branding(&mut self, metadata: BrandingMetadata) -> Result<()> {
        require!(self.authority == *ctx.accounts.authority.key, ErrorCode::Unauthorized);
        self.branding = Some(metadata);
        Ok(())
    }

    pub fn validate_anti_snipe(&mut self, wallet: &Pubkey, amount: u64) -> Result<()> {
        let clock = Clock::get()?;
        let current_time = clock.unix_timestamp;
        
        // Check if trading is enabled
        require!(self.trading_enabled, ErrorCode::TradingNotActive);
        
        // Initial launch protection (first 10 minutes)
        if current_time - self.launch_time < 600 {
            require!(
                amount <= self.total_liquidity / 1000, // 0.1% max
                ErrorCode::LaunchProtectionActive
            );
        }
        
        // First 24 hours protection
        if current_time - self.launch_time < 86400 {
            require!(
                amount <= self.total_liquidity / 2000, // 0.05% max
                ErrorCode::InitialDayRestriction
            );
            
            // 5-minute cooldown between trades
            require!(
                current_time - self.last_transaction_time >= 300,
                ErrorCode::CooldownNotElapsed
            );
        }
        
        // Block-based protections
        let current_block = clock.slot;
        if current_block == self.last_trade_block {
            self.trade_count_in_block += 1;
            require!(
                self.trade_count_in_block <= 3,
                ErrorCode::TooManyTradesInBlock
            );
        } else {
            self.last_trade_block = current_block;
            self.trade_count_in_block = 1;
        }
        
        // Check for blacklisted addresses
        require!(
            !self.blacklisted_addresses.contains(wallet),
            ErrorCode::AddressBlacklisted
        );
        
        Ok(())
    }

    pub fn update_suspicious_pattern(&mut self, wallet: &Pubkey) -> Result<()> {
        self.suspicious_patterns += 1;
        if self.suspicious_patterns >= 3 {
            self.blacklisted_addresses.push(*wallet);
        }
        Ok(())
    }

    pub fn validate_adaptive_rate_limit(&mut self, amount: u64) -> Result<()> {
        let clock = Clock::get()?;
        let current_block = clock.slot;
        
        // Check volume spike in current block
        let current_volume = self.volume_per_block.last().unwrap_or(&0);
        let previous_volume = self.volume_per_block.get(self.volume_per_block.len().saturating_sub(2)).unwrap_or(&0);
        
        let volume_increase = if previous_volume > &0 {
            ((current_volume - previous_volume) * 100) / previous_volume
        } else {
            0
        };
        
        // If volume spikes more than 10%, restrict trades
        if volume_increase > 10 {
            self.trade_count_in_block = 1; // Reset to 1 trade per block
            require!(
                self.trade_count_in_block <= 1,
                ErrorCode::VolumeSpikeRestriction
            );
        }
        
        Ok(())
    }

    pub fn validate_flash_loan_protection(&self, wallet: &Pubkey, amount: u64) -> Result<()> {
        // Check historical balances
        if let Some(history) = self.historical_balances.iter().find(|h| h.wallet == *wallet) {
            let recent_large_trade_threshold = self.total_liquidity / 20; // 5% of pool
            
            // Check if wallet had sufficient balance in previous blocks
            let had_sufficient_balance = history.balances.iter()
                .any(|(_, balance)| *balance >= amount);
                
            require!(
                had_sufficient_balance || amount < recent_large_trade_threshold,
                ErrorCode::SuspiciousLiquidityChange
            );
        }
        
        // Calculate price impact
        let price_impact = calculate_price_impact(amount, self.total_liquidity);
        require!(
            price_impact <= self.get_max_allowed_impact(),
            ErrorCode::PriceImpactTooHigh
        );
        
        Ok(())
    }

    pub fn validate_circuit_breakers(&mut self, price: u64) -> Result<()> {
        let clock = Clock::get()?;
        let current_time = clock.unix_timestamp;
        
        // Calculate price drop percentage
        let price_drop = if self.last_price > price {
            ((self.last_price - price) * 100) / self.last_price
        } else {
            0
        };
        
        // Compare to historical volatility
        let volatility_threshold = self.historical_volatility * 3;
        if price_drop > volatility_threshold {
            // Adaptive pause duration
            if self.is_market_stabilizing() {
                self.pause_duration = 1800; // 30 minutes
            } else {
                self.pause_duration = 7200; // 2 hours
            }
            
            self.paused = true;
            emit!(CircuitBreakerTriggeredEvent {
                timestamp: current_time,
                price_drop,
                pause_duration: self.pause_duration,
            });
        }
        
        Ok(())
    }

    pub fn process_buyback(&mut self) -> Result<()> {
        let clock = Clock::get()?;
        let current_time = clock.unix_timestamp;
        
        // Continuous buybacks from fees
        if current_time - self.last_buyback_time >= 86400 { // Daily buybacks
            let buyback_amount = self.daily_fee_revenue / 10; // 10% of daily fees
            if buyback_amount > 0 {
                execute_buyback(buyback_amount)?;
                self.last_buyback_time = current_time;
            }
        }
        
        Ok(())
    }

    fn is_market_stabilizing(&self) -> bool {
        // Check if recent volume and price movements show stability
        let recent_volume_stable = self.volume_per_block.iter()
            .rev()
            .take(5)
            .collect::<Vec<_>>()
            .windows(2)
            .all(|w| {
                let diff = if w[1] > w[0] { w[1] - w[0] } else { w[0] - w[1] };
                diff <= w[0] / 10 // Less than 10% change
            });
            
        recent_volume_stable
    }

    fn get_max_allowed_impact(&self) -> u64 {
        // Dynamic price impact limit based on liquidity and volume
        let base_impact = 30; // 3%
        if self.total_liquidity > 1_000_000 {
            base_impact / 2 // Stricter limits for larger pools
        } else {
            base_impact
        }
    }

    pub fn update_penalty_tier(&mut self, wallet: &Pubkey) -> Result<()> {
        if let Some(tier) = self.penalty_tiers.iter_mut().find(|t| t.wallet == *wallet) {
            tier.total_violations += 1;
            tier.last_violation_time = Clock::get()?.unix_timestamp;
            
            // Progressive penalties instead of instant ban
            tier.penalty_level = match tier.total_violations {
                1..=2 => 1,  // 2x cooldown
                3..=4 => 2,  // 4x cooldown
                5..=6 => 3,  // 8x cooldown
                _ => 4,      // 24-hour cooldown
            };
            
            tier.cooldown_multiplier = match tier.penalty_level {
                1 => 2,
                2 => 4,
                3 => 8,
                _ => 24 * 3600, // 24 hours in seconds
            };
        } else {
            self.penalty_tiers.push(PenaltyTier {
                wallet: *wallet,
                penalty_level: 1,
                last_violation_time: Clock::get()?.unix_timestamp,
                total_violations: 1,
                cooldown_multiplier: 2,
            });
        }
        Ok(())
    }

    pub fn request_lp_withdrawal(&mut self, wallet: &Pubkey, amount: u64) -> Result<()> {
        let current_time = Clock::get()?.unix_timestamp;
        let is_large = amount > self.total_liquidity / 20; // > 5% is large
        
        let unlock_time = if is_large {
            current_time + 7 * 24 * 3600 // 7 days for large withdrawals
        } else {
            current_time + 24 * 3600 // 24 hours for regular withdrawals
        };
        
        self.lp_withdrawal_delays.push(LPWithdrawal {
            wallet: *wallet,
            amount,
            request_time: current_time,
            unlock_time,
            is_large_withdrawal: is_large,
        });
        
        Ok(())
    }

    pub fn validate_oracle_price(&mut self, price: u64) -> Result<()> {
        let mut weighted_price = 0u64;
        let mut total_weight = 0u8;
        
        // Calculate weighted average from multiple oracles
        for oracle in self.oracle_price_feeds.iter() {
            if Clock::get()?.unix_timestamp - oracle.last_update < 300 { // Within 5 minutes
                weighted_price += oracle.last_price * oracle.weight as u64;
                total_weight += oracle.weight;
            }
        }
        
        require!(total_weight > 0, ErrorCode::StaleOracleData);
        let oracle_price = weighted_price / total_weight as u64;
        
        // Allow max 5% deviation from oracle price
        let max_deviation = oracle_price / 20;
        require!(
            price >= oracle_price.saturating_sub(max_deviation) &&
            price <= oracle_price.saturating_add(max_deviation),
            ErrorCode::PriceDeviationTooHigh
        );
        
        Ok(())
    }

    pub fn calculate_fee_refund(&self, wallet: &Pubkey) -> Result<u64> {
        if let Some(lp_info) = self.liquidity_hold_times.iter().find(|lp| lp.wallet == *wallet) {
            let holding_period = Clock::get()?.unix_timestamp - lp_info.first_hold_time;
            
            // Find applicable refund tier
            if let Some(refund) = self.fee_refund_schedule.iter()
                .filter(|r| lp_info.amount >= r.min_lp_amount)
                .find(|r| holding_period >= r.holding_period) {
                return Ok((self.daily_fee_revenue * refund.refund_percentage as u64) / 100);
            }
        }
        Ok(0)
    }
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct WalletCooldown {
    pub wallet: Pubkey,
    pub last_trade_time: i64,
    pub total_trades: u64,
    pub similar_wallets: Vec<Pubkey>,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct LiquidityHoldTime {
    pub wallet: Pubkey,
    pub first_hold_time: i64,
    pub amount: u64,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct HistoricalBalance {
    pub wallet: Pubkey,
    pub balances: Vec<(i64, u64)>, // (timestamp, balance)
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct PenaltyTier {
    pub wallet: Pubkey,
    pub penalty_level: u8,
    pub last_violation_time: i64,
    pub total_violations: u64,
    pub cooldown_multiplier: u64,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct LPWithdrawal {
    pub wallet: Pubkey,
    pub amount: u64,
    pub request_time: i64,
    pub unlock_time: i64,
    pub is_large_withdrawal: bool,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct OraclePriceFeed {
    pub oracle_id: Pubkey,
    pub last_price: u64,
    pub last_update: i64,
    pub weight: u8,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct GovernanceSettings {
    pub min_timelock: i64,
    pub emergency_timelock: i64,
    pub required_votes: u64,
    pub vote_duration: i64,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct FeeRefund {
    pub holding_period: i64,
    pub refund_percentage: u8,
    pub min_lp_amount: u64,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct BuybackSettings {
    pub min_price_drop: u8,
    pub max_daily_buyback: u64,
    pub community_vote_required: bool,
    pub execution_delay: i64,
}

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(init, payer = authority, mint::decimals = 9, mint::authority = authority)]
    pub mint: Account<'info, Mint>,
    #[account(mut)]
    pub authority: Signer<'info>,
    #[account(init, payer = authority, token::mint = mint, token::authority = authority)]
    pub liquidity_pool: Account<'info, TokenAccount>,
    #[account(init, payer = authority, token::mint = mint, token::authority = authority)]
    pub team_account: Account<'info, TokenAccount>,
    #[account(init, payer = authority, space = 8 + 32 + 1 + 8 + 8 + 8 + 8 + 8 + 8 + 8 + 8 + 8 + 8 + 8 + 8 + 8 + 8 + 8 + 8)]
    pub state: Account<'info, TokenState>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct ActivateTrading<'info> {
    #[account(mut)]
    pub state: Account<'info, TokenState>,
    pub authority: Signer<'info>,
}

#[derive(Accounts)]
pub struct UpdateLimits<'info> {
    #[account(mut)]
    pub state: Account<'info, TokenState>,
    pub authority: Signer<'info>,
}

#[derive(Accounts)]
pub struct UpdatePriceData<'info> {
    #[account(mut)]
    pub state: Account<'info, TokenState>,
    pub authority: Signer<'info>,
}

#[derive(Accounts)]
pub struct UpdateProtection<'info> {
    #[account(mut)]
    pub state: Account<'info, TokenState>,
    pub authority: Signer<'info>,
}

#[derive(Accounts)]
pub struct PauseTrading<'info> {
    #[account(mut)]
    pub state: Account<'info, TokenState>,
    pub authority: Signer<'info>,
}

#[derive(Accounts)]
pub struct CalculateFee<'info> {
    #[account(mut)]
    pub state: Account<'info, TokenState>,
    pub authority: Signer<'info>,
}

#[derive(Accounts)]
pub struct ValidateTrade<'info> {
    #[account(mut)]
    pub state: Account<'info, TokenState>,
    pub authority: Signer<'info>,
    pub trader: Signer<'info>,
}

#[derive(Accounts)]
pub struct UpdateBranding<'info> {
    #[account(mut)]
    pub state: Account<'info, TokenState>,
    pub authority: Signer<'info>,
}

#[derive(Accounts)]
pub struct AddLiquidity<'info> {
    #[account(mut)]
    pub state: Account<'info, TokenState>,
    pub liquidity_provider: Signer<'info>,
}

#[event]
pub struct TokenInitializedEvent {
    pub timestamp: i64,
    pub initial_supply: u64,
    pub liquidity_allocation: u64,
    pub team_allocation: u64,
    pub branding: Option<BrandingMetadata>,
}

#[event]
pub struct TradingPausedEvent {
    pub timestamp: i64,
}

#[event]
pub struct TradingResumedEvent {
    pub timestamp: i64,
}

#[event]
pub struct BrandingUpdatedEvent {
    pub timestamp: i64,
    pub metadata: BrandingMetadata,
}

#[event]
pub struct CircuitBreakerTriggeredEvent {
    pub timestamp: i64,
    pub price_drop: u64,
    pub pause_duration: u64,
}

#[error_code]
pub enum ErrorCode {
    #[msg("Unauthorized access")]
    Unauthorized,
    #[msg("Trading not yet activated")]
    TradingNotActive,
    #[msg("Trading is paused")]
    TradingPaused,
    #[msg("Transaction exceeds limit")]
    ExceedsTransactionLimit,
    #[msg("Wallet amount exceeds limit")]
    ExceedsWalletLimit,
    #[msg("Excessive price impact")]
    ExcessivePriceImpact,
    #[msg("Invalid parameter value")]
    InvalidParameter,
    #[msg("Cooldown period not elapsed")]
    CooldownNotElapsed,
    #[msg("Rate limit exceeded")]
    RateLimitExceeded,
    #[msg("Invalid supply amount")]
    InvalidSupply,
    #[msg("Supply amount too large")]
    SupplyTooLarge,
    #[msg("Exceeds accumulation phase limit")]
    ExceedsAccumulationLimit,
    #[msg("Exceeds trade size limit")]
    ExceedsTradeLimit,
    #[msg("Daily volume limit reached")]
    DailyVolumeExceeded,
    #[msg("Launch protection is active")]
    LaunchProtectionActive,
    #[msg("Initial day trading restriction")]
    InitialDayRestriction,
    #[msg("Too many trades in one block")]
    TooManyTradesInBlock,
    #[msg("Address is blacklisted")]
    AddressBlacklisted,
    #[msg("Volume spike detected, trading restricted")]
    VolumeSpikeRestriction,
    #[msg("Suspicious liquidity change detected")]
    SuspiciousLiquidityChange,
    #[msg("Price impact too high")]
    PriceImpactTooHigh,
    #[msg("Liquidity sniping detected")]
    LiquiditySnipingDetected,
    #[msg("Stale oracle data")]
    StaleOracleData,
    #[msg("Price deviation too high")]
    PriceDeviationTooHigh,
    #[msg("Insufficient price drop for buyback")]
    InsufficientPriceDrop,
    #[msg("Daily buyback limit reached")]
    DailyBuybackLimitReached,
    #[msg("Community approval required")]
    CommunityApprovalRequired,
    #[msg("Withdrawal locked")]
    WithdrawalLocked,
}

fn is_suspicious_pattern(amount: u64, is_sell: bool, state: &TokenState) -> bool {
    // Check for typical sniping patterns
    let clock = Clock::get().unwrap();
    let current_time = clock.unix_timestamp;
    
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