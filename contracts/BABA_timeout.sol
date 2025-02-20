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
        
        // Initialize base fields
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
        lockup.paused = false;
        
        // Initialize market metrics
        lockup.market_volume = 0;
        lockup.market_liquidity = total_locked;
        
        // Initialize governance parameters
        lockup.proposals = Vec::new();
        lockup.min_proposal_threshold = total_locked / 1000; // 0.1% of total supply
        lockup.discussion_period = 7 * 24 * 60 * 60;        // 7 days
        lockup.standard_voting_period = 5 * 24 * 60 * 60;   // 5 days
        lockup.emergency_voting_period = 24 * 60 * 60;      // 24 hours
        lockup.technical_voting_period = 21 * 24 * 60 * 60; // 21 days
        lockup.execution_timelock = 72 * 60 * 60;           // 72 hours
        lockup.emergency_execution_delay = 0;               // No delay for emergency
        lockup.last_proposal_id = 0;
        lockup.active_votes = Vec::new();
        
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

    pub fn validate_release(
        ctx: Context<Release>,
        amount: u64
    ) -> Result<()> {
        let lockup = &mut ctx.accounts.lockup;
        let clock = Clock::get()?;
        
        // Basic validation
        require!(!lockup.paused, ErrorCode::TimelockPaused);
        require!(amount > 0, ErrorCode::InvalidAmount);
        
        // Check release tier and apply restrictions
        let tier = lockup.get_release_tier(amount)?;
        
        // Validate cooldown period
        require!(
            clock.unix_timestamp - lockup.last_release_time >= tier.cooldown,
            ErrorCode::CooldownNotElapsed
        );
        
        // Check for suspicious patterns
        if is_suspicious_pattern(lockup, amount) {
            lockup.suspicious_patterns += 1;
            require!(
                lockup.suspicious_patterns < lockup.security_params.suspicious_pattern_threshold,
                ErrorCode::SuspiciousActivityDetected
            );
        }
        
        // Validate market conditions
        require!(
            validate_market_conditions(lockup, amount)?,
            ErrorCode::UnhealthyMarketConditions
        );
        
        // If oracle validation required, check price
        if tier.oracle_requirement {
            require!(
                validate_oracle_price(lockup)?,
                ErrorCode::OracleValidationFailed
            );
        }
        
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
    pub paused: bool,
    pub total_votes: u64,
    pub emergency_votes: u64,
    pub dynamic_multiplier: u8,
    pub market_volume: u64,
    pub market_liquidity: u64,
    
    // New security features
    pub max_release_per_interval: u64,    // Maximum amount that can be released per interval
    pub suspicious_patterns: u64,         // Counter for suspicious release patterns
    pub last_large_release_time: i64,     // Timestamp of last large release
    pub large_release_cooldown: i64,      // Cooldown period for large releases
    pub emergency_timelock: i64,          // Timelock for emergency actions
    pub min_vote_duration: i64,           // Minimum duration for votes
    pub oracle_price_threshold: u64,      // Price threshold for oracle validation
    pub release_tiers: Vec<ReleaseTier>,  // Tiered release structure
    pub market_metrics: MarketMetrics,    // Enhanced market tracking
    pub security_params: SecurityParams,   // Security parameters
    
    // Governance fields
    pub proposals: Vec<Proposal>,
    pub min_proposal_threshold: u64,      // Minimum tokens required to submit proposal
    pub discussion_period: i64,           // Discussion period duration (7 days)
    pub standard_voting_period: i64,      // Standard voting period (5 days)
    pub emergency_voting_period: i64,     // Emergency voting period (24 hours)
    pub technical_voting_period: i64,     // Technical voting period (21 days)
    pub execution_timelock: i64,          // Standard execution timelock (72 hours)
    pub emergency_execution_delay: i64,   // Emergency execution delay
    pub last_proposal_id: u64,           // Counter for proposal IDs
    pub active_votes: Vec<(Pubkey, u64, bool)>, // (voter, power, vote)
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct ReleaseTier {
    pub threshold: u64,           // Amount threshold for this tier
    pub cooldown: i64,           // Required cooldown period
    pub vote_requirement: u8,    // Required vote percentage
    pub oracle_requirement: bool, // Whether oracle validation is required
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct MarketMetrics {
    pub price_impact_threshold: u64,    // Maximum allowed price impact
    pub volume_24h: u64,               // 24-hour trading volume
    pub volatility_index: u64,         // Current volatility measure
    pub liquidity_health_score: u8,    // Overall liquidity health (0-100)
    pub last_update_time: i64,         // Last metrics update timestamp
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct SecurityParams {
    pub max_release_percentage: u8,     // Maximum % of total that can be released
    pub min_liquidity_ratio: u8,       // Minimum liquidity to total locked ratio
    pub emergency_cooldown: i64,        // Cooldown after emergency actions
    pub oracle_staleness_threshold: i64, // Maximum age of oracle data
    pub suspicious_pattern_threshold: u8, // Threshold for suspicious activity
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

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct Proposal {
    pub title: String,
    pub description: String,
    pub implementation_plan: String,
    pub voting_period: i64,
    pub execution_delay: i64,
    pub proposal_type: ProposalType,
    pub required_votes: u64,
    pub start_time: i64,
    pub end_time: i64,
    pub executed: bool,
    pub total_votes_for: u64,
    pub total_votes_against: u64,
    pub weighted_votes_for: u64,
    pub weighted_votes_against: u64,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq)]
pub enum ProposalType {
    Standard,
    Emergency,
    Technical,
}

impl LiquidityLock {
    pub fn submit_proposal(
        &mut self,
        proposal_type: ProposalType,
        title: String,
        description: String,
        implementation_plan: String,
    ) -> Result<()> {
        let clock = Clock::get()?;
        let current_time = clock.unix_timestamp;
        
        // Set voting period based on proposal type
        let (voting_period, execution_delay) = match proposal_type {
            ProposalType::Standard => (7 * 24 * 60 * 60, 72 * 60 * 60),  // 7 days voting, 72h delay
            ProposalType::Emergency => (24 * 60 * 60, 0),                // 24h voting, no delay
            ProposalType::Technical => (21 * 24 * 60 * 60, 72 * 60 * 60), // 21 days voting, 72h delay
        };

        let proposal = Proposal {
            title,
            description,
            implementation_plan,
            voting_period,
            execution_delay,
            proposal_type,
            required_votes: self.calculate_required_votes(proposal_type)?,
            start_time: current_time,
            end_time: current_time + voting_period,
            executed: false,
            total_votes_for: 0,
            total_votes_against: 0,
            weighted_votes_for: 0,
            weighted_votes_against: 0,
        };

        self.proposals.push(proposal);
        Ok(())
    }

    pub fn vote_on_proposal(
        &mut self,
        proposal_id: u64,
        vote_for: bool,
        voter: &Pubkey,
        voting_power: u64,
    ) -> Result<()> {
        let proposal = self.proposals.get_mut(proposal_id as usize)
            .ok_or(ErrorCode::InvalidProposal)?;
            
        let clock = Clock::get()?;
        require!(
            clock.unix_timestamp >= proposal.start_time 
            && clock.unix_timestamp <= proposal.end_time,
            ErrorCode::VotingPeriodInvalid
        );

        // Calculate time-weighted voting power
        let holding_duration = self.get_holding_duration(voter)?;
        let time_weight = 100 + std::cmp::min(
            (holding_duration / (365 * 24 * 60 * 60)) * 50,
            50
        );
        let weighted_power = (voting_power * time_weight as u64) / 100;

        if vote_for {
            proposal.total_votes_for += voting_power;
            proposal.weighted_votes_for += weighted_power;
        } else {
            proposal.total_votes_against += voting_power;
            proposal.weighted_votes_against += weighted_power;
        }

        Ok(())
    }

    pub fn execute_proposal(&mut self, proposal_id: u64) -> Result<()> {
        let proposal = self.proposals.get_mut(proposal_id as usize)
            .ok_or(ErrorCode::InvalidProposal)?;
            
        let clock = Clock::get()?;
        
        // Check voting period ended
        require!(
            clock.unix_timestamp > proposal.end_time,
            ErrorCode::VotingPeriodNotEnded
        );
        
        // Check execution delay
        require!(
            clock.unix_timestamp >= proposal.end_time + proposal.execution_delay,
            ErrorCode::ExecutionDelayNotElapsed
        );
        
        // Check if proposal passed
        let total_votes = proposal.weighted_votes_for + proposal.weighted_votes_against;
        require!(
            total_votes >= proposal.required_votes,
            ErrorCode::InsufficientVotes
        );
        
        let vote_percentage = (proposal.weighted_votes_for * 100) / total_votes;
        require!(
            vote_percentage >= self.governance_threshold as u64,
            ErrorCode::ProposalRejected
        );

        proposal.executed = true;
        Ok(())
    }

    fn calculate_required_votes(&self, proposal_type: ProposalType) -> Result<u64> {
        match proposal_type {
            ProposalType::Standard => self.total_locked / 10,  // 10% of total locked
            ProposalType::Emergency => self.total_locked / 4,  // 25% of total locked
            ProposalType::Technical => self.total_locked / 3,  // 33% of total locked
        }
    }

    fn get_holding_duration(&self, wallet: &Pubkey) -> Result<i64> {
        if let Some(hold_time) = self.liquidity_hold_times
            .iter()
            .find(|h| h.wallet == *wallet)
        {
            let clock = Clock::get()?;
            return Ok(clock.unix_timestamp - hold_time.first_hold_time);
        }
        Ok(0)
    }
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
    #[msg("Cooldown not elapsed")]
    CooldownNotElapsed,
    #[msg("Unhealthy market conditions")]
    UnhealthyMarketConditions,
    #[msg("Oracle validation failed")]
    OracleValidationFailed,
    #[msg("Suspicious activity detected")]
    SuspiciousActivityDetected,
    #[msg("Invalid proposal")]
    InvalidProposal,
    #[msg("Voting period invalid")]
    VotingPeriodInvalid,
    #[msg("Voting period not ended")]
    VotingPeriodNotEnded,
    #[msg("Execution delay not elapsed")]
    ExecutionDelayNotElapsed,
    #[msg("Insufficient votes")]
    InsufficientVotes,
    #[msg("Proposal rejected")]
    ProposalRejected,
}

impl LiquidityLock {
    pub fn get_release_tier(&self, amount: u64) -> Result<&ReleaseTier> {
        let matching_tier = self.release_tiers.iter()
            .filter(|tier| amount >= tier.threshold)
            .max_by_key(|tier| tier.threshold)
            .ok_or(ErrorCode::InvalidAmount)?;
        Ok(matching_tier)
    }

    pub fn validate_market_conditions(&self, amount: u64) -> Result<bool> {
        let metrics = &self.market_metrics;
        
        // Check market health score
        if metrics.liquidity_health_score < 50 {
            return Ok(false);
        }
        
        // Check price impact
        let price_impact = calculate_price_impact(amount, self.market_liquidity);
        if price_impact > metrics.price_impact_threshold {
            return Ok(false);
        }
        
        // Check volatility
        if metrics.volatility_index > self.security_params.max_volatility_threshold {
            return Ok(false);
        }
        
        // Check liquidity ratio
        let liquidity_ratio = (self.market_liquidity * 100) / self.total_locked;
        if liquidity_ratio < self.security_params.min_liquidity_ratio as u64 {
            return Ok(false);
        }
        
        Ok(true)
    }

    pub fn validate_oracle_price(&self) -> Result<bool> {
        let clock = Clock::get()?;
        
        // Check oracle staleness
        if clock.unix_timestamp - self.market_metrics.last_update_time > self.security_params.oracle_staleness_threshold {
            return Ok(false);
        }
        
        // Get weighted oracle price
        let oracle_price = self.get_weighted_oracle_price()?;
        
        // Check price deviation
        let current_price = self.market_metrics.current_price;
        let deviation = if oracle_price > current_price {
            ((oracle_price - current_price) * 100) / current_price
        } else {
            ((current_price - oracle_price) * 100) / oracle_price
        };
        
        Ok(deviation <= self.oracle_price_threshold)
    }

    pub fn is_suspicious_pattern(&self, amount: u64) -> bool {
        let clock = Clock::get().unwrap();
        let current_time = clock.unix_timestamp;
        
        // Check for large releases in short time
        if amount > self.max_release_per_interval {
            if current_time - self.last_large_release_time < self.large_release_cooldown {
                return true;
            }
        }
        
        // Check release frequency
        if current_time - self.last_release_time < self.min_release_interval / 2 {
            return true;
        }
        
        // Check market impact
        let impact = calculate_price_impact(amount, self.market_liquidity);
        if impact > self.market_metrics.price_impact_threshold * 2 {
            return true;
        }
        
        false
    }

    pub fn update_market_metrics(&mut self) -> Result<()> {
        let clock = Clock::get()?;
        let metrics = &mut self.market_metrics;
        
        // Update 24h volume if needed
        if clock.unix_timestamp - metrics.last_update_time >= 86400 {
            metrics.volume_24h = 0;
        }
        
        // Calculate volatility index
        metrics.volatility_index = calculate_volatility(
            self.market_metrics.price_history.as_slice()
        )?;
        
        // Update liquidity health score
        metrics.liquidity_health_score = calculate_health_score(
            self.market_liquidity,
            self.total_locked,
            metrics.volume_24h,
            metrics.volatility_index
        )?;
        
        metrics.last_update_time = clock.unix_timestamp;
        Ok(())
    }

    pub fn process_emergency_action(&mut self) -> Result<()> {
        let clock = Clock::get()?;
        
        // Check emergency timelock
        require!(
            clock.unix_timestamp - self.last_emergency_action >= self.emergency_timelock,
            ErrorCode::TimelockActive
        );
        
        // Check vote requirements
        require!(
            self.emergency_votes >= self.total_votes * self.governance_threshold as u64 / 100,
            ErrorCode::InsufficientVotes
        );
        
        // Apply emergency action
        self.is_emergency_unlocked = true;
        self.paused = true;
        self.last_emergency_action = clock.unix_timestamp;
        
        emit!(EmergencyActionEvent {
            timestamp: clock.unix_timestamp,
            total_votes: self.total_votes,
            emergency_votes: self.emergency_votes,
        });
        
        Ok(())
    }
}

// Helper functions
fn calculate_price_impact(amount: u64, liquidity: u64) -> u64 {
    if liquidity == 0 {
        return u64::MAX;
    }
    (amount * 100) / liquidity
}

fn calculate_volatility(price_history: &[(i64, u64)]) -> Result<u64> {
    if price_history.len() < 2 {
        return Ok(0);
    }
    
    let mut sum_deviation = 0u64;
    let mut prev_price = price_history[0].1;
    
    for (_timestamp, price) in price_history.iter().skip(1) {
        let deviation = if *price > prev_price {
            (*price - prev_price) * 100 / prev_price
        } else {
            (prev_price - *price) * 100 / prev_price
        };
        sum_deviation += deviation;
        prev_price = *price;
    }
    
    Ok(sum_deviation / (price_history.len() as u64 - 1))
}

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

#[event]
pub struct EmergencyActionEvent {
    pub timestamp: i64,
    pub total_votes: u64,
    pub emergency_votes: u64,
}

#[event]
pub struct ProposalCreatedEvent {
    pub timestamp: i64,
    pub proposal_id: u64,
    pub proposal_type: ProposalType,
    pub title: String,
    pub creator: Pubkey,
}

#[event]
pub struct VoteCastEvent {
    pub timestamp: i64,
    pub proposal_id: u64,
    pub voter: Pubkey,
    pub vote_for: bool,
    pub voting_power: u64,
    pub weighted_power: u64,
}

#[event]
pub struct ProposalExecutedEvent {
    pub timestamp: i64,
    pub proposal_id: u64,
    pub total_votes_for: u64,
    pub total_votes_against: u64,
    pub weighted_votes_for: u64,
    pub weighted_votes_against: u64,
}

#[event]
pub struct ProposalCancelledEvent {
    pub timestamp: i64,
    pub proposal_id: u64,
    pub canceller: Pubkey,
} 