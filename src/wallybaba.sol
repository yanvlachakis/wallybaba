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
        let current_time = Clock::get()?.unix_timestamp;
        let time_since_launch = current_time - state.launch_timestamp;
        
        if is_sell {
            // After 7.5 months (19,440,000 seconds), no restrictions
            if time_since_launch >= 19_440_000 {
                // Only maintain basic anti-flash-loan protection
                if amount > state.total_daily_volume / 50 { // > 2% of daily volume
                    require!(
                        current_time - state.last_transaction_time >= 300, // 5 minutes cooldown
                        ErrorCode::CooldownNotElapsed
                    );
                }
            } else {
                // Graduated restrictions for first 7.5 months
                let max_sell_percentage = if time_since_launch < 6_480_000 { // First 75 days
                    25 // 0.25%
                } else if time_since_launch < 12_960_000 { // 75-150 days
                    let progress = (time_since_launch - 6_480_000) as f64 / (6_480_000 as f64);
                    (25.0 + (progress * 25.0)) as u64
                } else if time_since_launch < 19_440_000 { // 150-225 days
                    let progress = (time_since_launch - 12_960_000) as f64 / (6_480_000 as f64);
                    (50.0 + (progress * 25.0)) as u64
                } else {
                    75 // 0.75% (shouldn't reach here due to above check)
                };
                
                require!(
                    amount <= state.total_liquidity * max_sell_percentage / 10000,
                    ErrorCode::ExceedsTradeLimit
                );
                
                // Stricter cooldown during protection period
                if amount > state.total_daily_volume / 100 { // > 1% of daily volume
                    require!(
                        current_time - state.last_transaction_time >= 1800, // 30 minutes
                        ErrorCode::CooldownNotElapsed
                    );
                }
            }
            
            // Reset daily volume tracking if needed
            if current_time - state.last_volume_reset >= 86400 { // 24 hours
                state.total_daily_volume = 0;
                state.wallet_daily_volume = 0;
                state.last_volume_reset = current_time;
            }
            
            // Update volume tracking
            state.total_daily_volume = state.total_daily_volume.saturating_add(amount);
            state.wallet_daily_volume = state.wallet_daily_volume.saturating_add(amount);
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
    pub launch_timestamp: i64,  // Track launch time for 3-month period
    pub progressive_fees_enabled: bool,
    pub max_sell_percent: u64,  // Dynamic max sell percentage
    pub total_daily_volume: u64,
    pub wallet_daily_volume: u64,
    pub last_volume_reset: i64,
    pub branding: Option<BrandingMetadata>,
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
}

#[derive(Accounts)]
pub struct UpdateBranding<'info> {
    #[account(mut)]
    pub state: Account<'info, TokenState>,
    pub authority: Signer<'info>,
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
}
