use anchor_lang::prelude::*;
use anchor_spl::token::{self, Mint, Token, TokenAccount, Transfer};
use std::cmp;

declare_id!("YOUR_WALLET_PUBLIC_KEY_HERE");

#[program]
pub mod wallybaba_lp_timelock {
    use super::*;

    pub fn initialize(
        ctx: Context<Initialize>,
        total_locked: u64,
        min_release_interval: i64,
        governance_threshold: u8,
    ) -> Result<()> {
        require!(total_locked > 0, ErrorCode::InvalidAmount);
        require!(min_release_interval > 0, ErrorCode::InvalidInterval);
        require!(
            governance_threshold > 0 && governance_threshold <= 100,
            ErrorCode::InvalidGovernanceThreshold
        );

        let lockup = &mut ctx.accounts.lockup;
        let clock = Clock::get()?;
        
        // Verify time parameters
        let current_time = clock.unix_timestamp;
        let end_time = current_time + (3 * 365 * 24 * 60 * 60); // 3 years
        require!(end_time > current_time, ErrorCode::InvalidTimeParameters);
        
        lockup.owner = *ctx.accounts.owner.key;
        lockup.start_time = current_time;
        lockup.end_time = end_time;
        lockup.total_locked = total_locked;
        lockup.released = 0;
        lockup.last_release_time = current_time;
        lockup.min_release_interval = min_release_interval;
        lockup.governance_threshold = governance_threshold;
        lockup.is_emergency_unlocked = false;
        lockup.total_votes = 0;
        lockup.emergency_votes = 0;
        lockup.dynamic_multiplier = 100; // 100 = 1.0x (base rate)
        lockup.paused = false;  // New emergency pause feature
        
        // Initialize market metrics
        lockup.market_volume = 0;
        lockup.market_liquidity = total_locked;
        
        // Emit initialization event
        emit!(TimelockInitializedEvent {
            timestamp: current_time,
            total_locked,
            end_time,
            governance_threshold,
        });

        Ok(())
    }

    pub fn release_tokens(ctx: Context<Release>) -> Result<()> {
        let lockup = &mut ctx.accounts.lockup;
        let clock = Clock::get()?;
        
        // Check if emergency unlock is active
        if !lockup.is_emergency_unlocked {
            // Verify release interval
            require!(
                clock.unix_timestamp - lockup.last_release_time >= lockup.min_release_interval,
                ErrorCode::ReleaseTooEarly
            );
        }
        
        let elapsed_time = cmp::max(clock.unix_timestamp - lockup.start_time, 0);
        let total_duration = lockup.end_time - lockup.start_time;
        
        // Enhanced release schedule with 6-month acceleration
        let base_release_rate = if elapsed_time < 5_184_000 { // First 60 days
            // Release 50% in first 60 days
            (lockup.total_locked * 50 / 100) * elapsed_time as u64 / 5_184_000
        } else if elapsed_time < 15_552_000 { // Next 120 days
            // Release additional 30% in next 120 days
            let first_phase = lockup.total_locked * 50 / 100;
            let second_phase_progress = (elapsed_time - 5_184_000) as u64;
            first_phase + (lockup.total_locked * 30 / 100) * second_phase_progress / 10_368_000
        } else {
            // Release remaining 20% in final period
            let progress = (elapsed_time - 15_552_000) as u64;
            let remaining_time = total_duration - 15_552_000;
            let already_released = lockup.total_locked * 80 / 100;
            already_released + (lockup.total_locked * 20 / 100) * progress / remaining_time as u64
        };
        
        // Apply dynamic multiplier based on market conditions
        let dynamic_amount = (base_release_rate * lockup.dynamic_multiplier as u64) / 100;
        let amount_releasable = cmp::min(dynamic_amount, lockup.total_locked);
        let amount_to_release = amount_releasable.saturating_sub(lockup.released);

        require!(amount_to_release > 0, ErrorCode::NoTokensAvailable);

        // Transfer LP tokens to the liquidity pool
        let cpi_accounts = Transfer {
            from: ctx.accounts.locked_lp_vault.to_account_info(),
            to: ctx.accounts.liquidity_pool.to_account_info(),
            authority: ctx.accounts.owner.to_account_info(),
        };
        let cpi_ctx = CpiContext::new(ctx.accounts.token_program.to_account_info(), cpi_accounts);
        token::transfer(cpi_ctx, amount_to_release)?;

        lockup.released += amount_to_release;
        lockup.last_release_time = clock.unix_timestamp;
        
        emit!(LiquidityReleaseEvent {
            amount: amount_to_release,
            timestamp: clock.unix_timestamp,
            remaining: lockup.total_locked - lockup.released,
            multiplier: lockup.dynamic_multiplier,
        });
        
        Ok(())
    }

    pub fn update_market_metrics(
        ctx: Context<UpdateMetrics>,
        volume: u64,
        liquidity: u64
    ) -> Result<()> {
        let lockup = &mut ctx.accounts.lockup;
        require!(ctx.accounts.owner.key() == &lockup.owner, ErrorCode::Unauthorized);
        
        lockup.market_volume = volume;
        lockup.market_liquidity = liquidity;
        
        // Adjust dynamic multiplier based on market conditions
        let liquidity_ratio = (liquidity * 100) / lockup.total_locked;
        if liquidity_ratio < 50 {  // If liquidity drops below 50%
            lockup.dynamic_multiplier = 150;  // Increase release rate by 1.5x
        } else if liquidity_ratio > 150 {  // If liquidity is above 150%
            lockup.dynamic_multiplier = 75;   // Decrease release rate to 0.75x
        } else {
            lockup.dynamic_multiplier = 100;  // Normal release rate
        }
        
        Ok(())
    }

    pub fn propose_emergency_unlock(ctx: Context<ProposeEmergency>) -> Result<()> {
        let lockup = &mut ctx.accounts.lockup;
        
        // Verify caller has LP tokens staked
        let voter_balance = ctx.accounts.voter_token_account.amount;
        require!(voter_balance > 0, ErrorCode::InsufficientVotingPower);
        
        // Record vote
        lockup.emergency_votes += voter_balance;
        lockup.total_votes += voter_balance;
        
        // Check if threshold is met
        let vote_percentage = (lockup.emergency_votes * 100) / lockup.total_votes;
        if vote_percentage >= lockup.governance_threshold {
            lockup.is_emergency_unlocked = true;
            
            emit!(EmergencyUnlockEvent {
                timestamp: Clock::get()?.unix_timestamp,
                total_votes: lockup.total_votes,
                emergency_votes: lockup.emergency_votes,
            });
        }
        
        Ok(())
    }

    pub fn cancel_emergency_unlock(ctx: Context<CancelEmergency>) -> Result<()> {
        let lockup = &mut ctx.accounts.lockup;
        require!(ctx.accounts.owner.key() == &lockup.owner, ErrorCode::Unauthorized);
        
        lockup.is_emergency_unlocked = false;
        lockup.emergency_votes = 0;
        lockup.total_votes = 0;
        
        emit!(EmergencyUnlockCancelledEvent {
            timestamp: Clock::get()?.unix_timestamp,
        });
        
        Ok(())
    }

    pub fn pause_timelock(ctx: Context<PauseTimelock>) -> Result<()> {
        let lockup = &mut ctx.accounts.lockup;
        require!(ctx.accounts.owner.key() == &lockup.owner, ErrorCode::Unauthorized);
        require!(!lockup.paused, ErrorCode::AlreadyPaused);

        lockup.paused = true;
        
        emit!(TimelockPausedEvent {
            timestamp: Clock::get()?.unix_timestamp,
        });
        
        Ok(())
    }

    pub fn resume_timelock(ctx: Context<PauseTimelock>) -> Result<()> {
        let lockup = &mut ctx.accounts.lockup;
        require!(ctx.accounts.owner.key() == &lockup.owner, ErrorCode::Unauthorized);
        require!(lockup.paused, ErrorCode::NotPaused);

        lockup.paused = false;
        
        emit!(TimelockResumedEvent {
            timestamp: Clock::get()?.unix_timestamp,
        });
        
        Ok(())
    }

    pub fn revoke_vote(ctx: Context<RevokeVote>) -> Result<()> {
        let lockup = &mut ctx.accounts.lockup;
        let voter_balance = ctx.accounts.voter_token_account.amount;
        
        require!(voter_balance > 0, ErrorCode::InsufficientVotingPower);
        require!(lockup.emergency_votes >= voter_balance, ErrorCode::InvalidVoteRevocation);
        
        lockup.emergency_votes = lockup.emergency_votes.saturating_sub(voter_balance);
        lockup.total_votes = lockup.total_votes.saturating_sub(voter_balance);
        
        emit!(VoteRevokedEvent {
            timestamp: Clock::get()?.unix_timestamp,
            voter: *ctx.accounts.voter.key,
            amount: voter_balance,
        });
        
        Ok(())
    }

    pub fn update_liquidity_requirements(
        ctx: Context<UpdateLiquidity>,
        new_threshold: Option<u64>,
        new_min_requirement: Option<u64>
    ) -> Result<()> {
        let lockup = &mut ctx.accounts.lockup;
        require!(ctx.accounts.owner.key() == &lockup.owner, ErrorCode::Unauthorized);
        
        if let Some(threshold) = new_threshold {
            lockup.sustained_liquidity_threshold = threshold;
        }
        
        if let Some(min_req) = new_min_requirement {
            lockup.min_liquidity_requirement = min_req;
        }
        
        emit!(LiquidityRequirementsUpdatedEvent {
            timestamp: Clock::get()?.unix_timestamp,
            new_threshold: lockup.sustained_liquidity_threshold,
            new_min_requirement: lockup.min_liquidity_requirement,
        });
        
        Ok(())
    }

    pub fn check_liquidity_health(ctx: Context<CheckLiquidity>) -> Result<()> {
        let lockup = &mut ctx.accounts.lockup;
        let clock = Clock::get()?;
        
        // Check if we're past accumulation phase
        if clock.unix_timestamp >= lockup.accumulation_end_time {
            // Verify sustained liquidity
            if lockup.market_liquidity >= lockup.sustained_liquidity_threshold {
                // Relax restrictions by updating dynamic_multiplier
                lockup.dynamic_multiplier = 100;  // Reset to normal (1.0x)
            }
        }
        
        // Enforce minimum liquidity requirement
        require!(
            lockup.market_liquidity >= lockup.min_liquidity_requirement,
            ErrorCode::InsufficientLiquidity
        );
        
        Ok(())
    }
}

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(init, payer = owner, space = 8 + 32 + 8 + 8 + 8 + 8 + 8 + 8 + 1 + 8 + 8 + 8 + 8 + 8)]
    pub lockup: Account<'info, LiquidityLock>,
    #[account(mut)]
    pub owner: Signer<'info>,
    #[account(mut)]
    pub locked_lp_vault: Account<'info, TokenAccount>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct Release<'info> {
    #[account(mut)]
    pub lockup: Account<'info, LiquidityLock>,
    #[account(mut)]
    pub owner: Signer<'info>,
    #[account(mut)]
    pub locked_lp_vault: Account<'info, TokenAccount>,
    #[account(mut)]
    pub liquidity_pool: Account<'info, TokenAccount>,
    pub token_program: Program<'info, Token>,
}

#[derive(Accounts)]
pub struct UpdateMetrics<'info> {
    #[account(mut)]
    pub lockup: Account<'info, LiquidityLock>,
    pub owner: Signer<'info>,
}

#[derive(Accounts)]
pub struct ProposeEmergency<'info> {
    #[account(mut)]
    pub lockup: Account<'info, LiquidityLock>,
    pub voter: Signer<'info>,
    pub voter_token_account: Account<'info, TokenAccount>,
}

#[derive(Accounts)]
pub struct CancelEmergency<'info> {
    #[account(mut)]
    pub lockup: Account<'info, LiquidityLock>,
    pub owner: Signer<'info>,
}

#[derive(Accounts)]
pub struct PauseTimelock<'info> {
    #[account(mut)]
    pub lockup: Account<'info, LiquidityLock>,
    pub owner: Signer<'info>,
}

#[derive(Accounts)]
pub struct RevokeVote<'info> {
    #[account(mut)]
    pub lockup: Account<'info, LiquidityLock>,
    pub voter: Signer<'info>,
    pub voter_token_account: Account<'info, TokenAccount>,
}

#[derive(Accounts)]
pub struct UpdateLiquidity<'info> {
    #[account(mut)]
    pub lockup: Account<'info, LiquidityLock>,
    pub owner: Signer<'info>,
}

#[derive(Accounts)]
pub struct CheckLiquidity<'info> {
    #[account(mut)]
    pub lockup: Account<'info, LiquidityLock>,
}

#[account]
pub struct LiquidityLock {
    pub owner: Pubkey,
    pub start_time: i64,
    pub end_time: i64,
    pub total_locked: u64,
    pub released: u64,
    pub last_release_time: i64,
    pub min_release_interval: i64,
    pub governance_threshold: u8,
    pub is_emergency_unlocked: bool,
    pub paused: bool,  // New emergency pause state
    pub total_votes: u64,
    pub emergency_votes: u64,
    pub dynamic_multiplier: u8,
    pub market_volume: u64,
    pub market_liquidity: u64,
    pub sustained_liquidity_threshold: u64,  // Threshold for relaxing restrictions
    pub accumulation_end_time: i64,         // End of 3-month accumulation phase
    pub min_liquidity_requirement: u64,     // Minimum liquidity requirement
}

#[event]
pub struct LiquidityReleaseEvent {
    pub amount: u64,
    pub timestamp: i64,
    pub remaining: u64,
    pub multiplier: u8,
}

#[event]
pub struct EmergencyUnlockEvent {
    pub timestamp: i64,
    pub total_votes: u64,
    pub emergency_votes: u64,
}

#[event]
pub struct EmergencyUnlockCancelledEvent {
    pub timestamp: i64,
}

#[event]
pub struct TimelockInitializedEvent {
    pub timestamp: i64,
    pub total_locked: u64,
    pub end_time: i64,
    pub governance_threshold: u8,
}

#[event]
pub struct TimelockPausedEvent {
    pub timestamp: i64,
}

#[event]
pub struct TimelockResumedEvent {
    pub timestamp: i64,
}

#[event]
pub struct VoteRevokedEvent {
    pub timestamp: i64,
    pub voter: Pubkey,
    pub amount: u64,
}

#[event]
pub struct LiquidityRequirementsUpdatedEvent {
    pub timestamp: i64,
    pub new_threshold: u64,
    pub new_min_requirement: u64,
}

#[error_code]
pub enum ErrorCode {
    #[msg("No tokens available for release yet.")]
    NoTokensAvailable,
    #[msg("Release interval not elapsed")]
    ReleaseTooEarly,
    #[msg("Unauthorized access")]
    Unauthorized,
    #[msg("Invalid governance threshold")]
    InvalidGovernanceThreshold,
    #[msg("Insufficient voting power")]
    InsufficientVotingPower,
    #[msg("Invalid vote revocation")]
    InvalidVoteRevocation,
    #[msg("Invalid amount")]
    InvalidAmount,
    #[msg("Invalid interval")]
    InvalidInterval,
    #[msg("Invalid time parameters")]
    InvalidTimeParameters,
    #[msg("Timelock is paused")]
    TimelockPaused,
    #[msg("Timelock is already paused")]
    AlreadyPaused,
    #[msg("Timelock is not paused")]
    NotPaused,
    #[msg("Insufficient liquidity")]
    InsufficientLiquidity,
} 