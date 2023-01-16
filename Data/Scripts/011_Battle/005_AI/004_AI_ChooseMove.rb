class Battle::AI
  MOVE_FAIL_SCORE    = 25
  MOVE_USELESS_SCORE = 60   # Move predicted to do nothing or just be detrimental
  MOVE_BASE_SCORE    = 100

  # Returns a value between 0.0 and 1.0. All move scores are lowered by this
  # value multiplied by the highest-scoring move's score.
  def move_score_threshold
    return 0.6 + 0.35 * (([@trainer.skill, 100].min / 100.0) ** 0.5)   # 0.6 to 0.95
  end

  #=============================================================================
  # Get scores for the user's moves (done before any action is assessed).
  # NOTE: For any move with a target type that can target a foe (or which
  #       includes a foe(s) if it has multiple targets), the score calculated
  #       for a target ally will be inverted. The MoveHandlers for those moves
  #       should therefore treat an ally as a foe when calculating a score
  #       against it.
  #=============================================================================
  def pbGetMoveScores
    choices = []
    @user.battler.eachMoveWithIndex do |move, idxMove|
      # Unchoosable moves aren't considered
      if !@battle.pbCanChooseMove?(@user.index, idxMove, false)
        if move.pp == 0 && move.total_pp > 0
          PBDebug.log_ai("#{@user.name} cannot use #{move.name} (no PP left)")
        else
          PBDebug.log_ai("#{@user.name} cannot choose to use #{move.name}")
        end
        next
      end
      PBDebug.log_ai("#{@user.name} is considering using #{move.name}...")
      # Set up move in class variables
      set_up_move_check(move)
      # Predict whether the move will fail (generally)
      if @trainer.has_skill_flag?("PredictMoveFailure") && pbPredictMoveFailure
        PBDebug.log_score_change(MOVE_FAIL_SCORE - MOVE_BASE_SCORE, "move will fail")
        add_move_to_choices(choices, idxMove, MOVE_FAIL_SCORE)
        next
      end
      target_data = @move.pbTarget(@user.battler)
      # TODO: Alter target_data if user has Protean and move is Curse.
      case target_data.num_targets
      when 0   # No targets, affects the user or a side or the whole field
        # Includes: BothSides, FoeSide, None, User, UserSide
        score = MOVE_BASE_SCORE
        PBDebug.logonerr { score = pbGetMoveScore }
        add_move_to_choices(choices, idxMove, score)
      when 1   # One target to be chosen by the trainer
        # Includes: Foe, NearAlly, NearFoe, NearOther, Other, RandomNearFoe, UserOrNearAlly
        # TODO: Figure out first which targets are valid. Includes the call to
        #       pbMoveCanTarget?, but also includes move-redirecting effects
        #       like Lightning Rod. Skip any battlers that can't be targeted.
        num_targets = 0
        @battle.allBattlers.each do |b|
          next if !@battle.pbMoveCanTarget?(@user.battler.index, b.index, target_data)
          # TODO: Should this sometimes consider targeting an ally? See def
          #       pbGetMoveScoreAgainstTarget for more information.
          next if target_data.targets_foe && !@user.battler.opposes?(b)
          score = MOVE_BASE_SCORE
          PBDebug.logonerr { score = pbGetMoveScore([b]) }
          add_move_to_choices(choices, idxMove, score, b.index)
          num_targets += 1
        end
        PBDebug.log("     no valid targets") if num_targets == 0
      else   # Multiple targets at once
        # Includes: AllAllies, AllBattlers, AllFoes, AllNearFoes, AllNearOthers, UserAndAllies
        targets = []
        @battle.allBattlers.each do |b|
          next if !@battle.pbMoveCanTarget?(@user.battler.index, b.index, target_data)
          targets.push(b)
        end
        score = MOVE_BASE_SCORE
        PBDebug.logonerr { score = pbGetMoveScore(targets) }
        add_move_to_choices(choices, idxMove, score)
      end
    end
    @battle.moldBreaker = false
    return choices
  end

  def add_move_to_choices(choices, idxMove, score, idxTarget = -1)
    choices.push([idxMove, score, idxTarget])
    # If the user is a wild Pokémon, doubly prefer one of its moves (the choice
    # is random but consistent and does not correlate to any other property of
    # the user)
    if @user.wild? && @user.pokemon.personalID % @user.battler.moves.length == idxMove
      choices.push([idxMove, score, idxTarget])
    end
  end

  #=============================================================================
  # Set some extra class variables for the move/target combo being assessed.
  #=============================================================================
  def set_up_move_check(move)
    case move.function
    when "UseLastMoveUsed"
      if @battle.lastMoveUsed &&
         !move.moveBlacklist.include?(GameData::Move.get(@battle.lastMoveUsed).function_code)
        move = Battle::Move.from_pokemon_move(@battle, Pokemon::Move.new(@battle.lastMoveUsed))
      end
    when "UseLastMoveUsedByTarget"
      if target.battler.lastRegularMoveUsed &&
         GameData::Move.get(target.battler.lastRegularMoveUsed).flags.any? { |f| f[/^CanMirrorMove$/i] }
        move = Battle::Move.from_pokemon_move(@battle, Pokemon::Move.new(target.battler.lastRegularMoveUsed))
      end
    when "UseMoveDependingOnEnvironment"
      move.pbOnStartUse(@user.battler, [])   # Determine which move is used instead
      move = Battle::Move.from_pokemon_move(@battle, Pokemon::Move.new(move.npMove))
    end
    @move.set_up(move, @user)
    @battle.moldBreaker = @user.has_mold_breaker?
  end

  def set_up_move_check_target(target)
    @target = (target) ? @battlers[target.index] : nil
    @target&.refresh_battler
  end

  #=============================================================================
  # Returns whether the move will definitely fail (assuming no battle conditions
  # change between now and using the move).
  # TODO: Add skill checks in here for particular calculations?
  #=============================================================================
  def pbPredictMoveFailure
    # TODO: Something involving user.battler.usingMultiTurnAttack? (perhaps
    #       earlier than this?).
    # User is asleep and will not wake up
    return true if @user.battler.asleep? && @user.statusCount > 1 && !@move.move.usableWhenAsleep?
    # User is awake and can't use moves that are only usable when asleep
    return true if !@user.battler.asleep? && @move.move.usableWhenAsleep?
    # User will be truanting
    return true if @user.has_active_ability?(:TRUANT) && @user.effects[PBEffects::Truant]
    # Primal weather
    return true if @battle.pbWeather == :HeavyRain && @move.rough_type == :FIRE
    return true if @battle.pbWeather == :HarshSun && @move.rough_type == :WATER
    # Move effect-specific checks
    return true if Battle::AI::Handlers.move_will_fail?(@move.function, @move, @user, self, @battle)
    return false
  end

  def pbPredictMoveFailureAgainstTarget
    # Move effect-specific checks
    return true if Battle::AI::Handlers.move_will_fail_against_target?(@move.function, @move, @user, @target, self, @battle)
    # Immunity to priority moves because of Psychic Terrain
    return true if @battle.field.terrain == :Psychic && @target.battler.affectedByTerrain? &&
                   @target.opposes?(@user) && @move.rough_priority(@user) > 0
    # Immunity because of ability
    # TODO: Check for target-redirecting abilities that also provide immunity.
    #       If an ally has such an ability, may want to just not prefer the move
    #       instead of predicting its failure, as might want to hit the ally
    #       after all.
    return true if @move.move.pbImmunityByAbility(@user.battler, @target.battler, false)
    # Immunity because of Dazzling/Queenly Majesty
    if @move.rough_priority(@user) > 0 && @target.opposes?(@user)
      each_same_side_battler(@target.side) do |b, i|
        return true if b.has_active_ability?([:DAZZLING, :QUEENLYMAJESTY])
      end
    end
    # Type immunity
    calc_type = @move.rough_type
    typeMod = @move.move.pbCalcTypeMod(calc_type, @user.battler, @target.battler)
    return true if @move.move.pbDamagingMove? && Effectiveness.ineffective?(typeMod)
    # Dark-type immunity to moves made faster by Prankster
    return true if Settings::MECHANICS_GENERATION >= 7 && @move.statusMove? &&
                   @user.has_active_ability?(:PRANKSTER) && @target.has_type?(:DARK) && @target.opposes?(@user)
    # Airborne-based immunity to Ground moves
    return true if @move.damagingMove? && calc_type == :GROUND &&
                   @target.battler.airborne? && !@move.move.hitsFlyingTargets?
    # Immunity to powder-based moves
    return true if @move.move.powderMove? && !@target.battler.affectedByPowder?
    # Substitute
    return true if @target.effects[PBEffects::Substitute] > 0 && @move.statusMove? &&
                   !@move.move.ignoresSubstitute?(@user.battler) && @user.index != @target.index
    return false
  end

  #=============================================================================
  # Get a score for the given move being used against the given target.
  # Assumes def set_up_move_check has previously been called.
  #=============================================================================
  def pbGetMoveScore(targets = nil)
    # Get the base score for the move
    score = MOVE_BASE_SCORE
    # Scores for each target in turn
    if targets
      # Reset the base score for the move (each target will add its own score)
      score = 0
      # TODO: Distinguish between affected foes and affected allies?
      affected_targets = 0
      # Get a score for the move against each target in turn
      targets.each do |target|
        set_up_move_check_target(target)
        t_score = pbGetMoveScoreAgainstTarget
        next if t_score < 0
        score += t_score
        affected_targets += 1
      end
      # Set the default score if no targets were affected
      if affected_targets == 0
        score = (@trainer.has_skill_flag?("PredictMoveFailure")) ? MOVE_USELESS_SCORE : MOVE_BASE_SCORE
      end
      # Score based on how many targets were affected
      if affected_targets == 0 && @trainer.has_skill_flag?("PredictMoveFailure")
        if !@move.move.worksWithNoTargets?
          PBDebug.log_score_change(MOVE_FAIL_SCORE - MOVE_BASE_SCORE, "move will fail")
          return MOVE_FAIL_SCORE
        end
      else
        # TODO: Can this accounting for multiple targets be improved somehow?
        score /= affected_targets if affected_targets > 1   # Average the score against multiple targets
        # Bonus for affecting multiple targets
        if @trainer.has_skill_flag?("PreferMultiTargetMoves") && affected_targets > 1
          old_score = score
          score += (affected_targets - 1) * 10
          PBDebug.log_score_change(score - old_score, "affects multiple battlers")
        end
      end
    end
    # If we're here, the move either has no targets or at least one target will
    # be affected (or the move is usable even if no targets are affected, e.g.
    # Self-Destruct)
    if @trainer.has_skill_flag?("ScoreMoves")
      # Modify the score according to the move's effect
      old_score = score
      score = Battle::AI::Handlers.apply_move_effect_score(@move.function,
         score, @move, @user, self, @battle)
      PBDebug.log_score_change(score - old_score, "function code modifier (generic)")
      # Modify the score according to various other effects
      score = Battle::AI::Handlers.apply_general_move_score_modifiers(
         score, @move, @user, self, @battle)
    end
    score = score.to_i
    score = 0 if score < 0
    return score
  end

  #=============================================================================
  # Returns the score of @move being used against @target. A return value of -1
  # means the move will fail or do nothing against the target.
  # Assumes def set_up_move_check and def set_up_move_check_target have
  # previously been called.
  # TODO: Add something in here (I think) to specially score moves used against
  #       an ally and the ally has an ability that will benefit from being hit
  #       by the move.
  # TODO: The above also applies if the move is Heal Pulse or a few other moves
  #       like that, which CAN target a foe but you'd never do so. Maybe use a
  #       move flag to determine such moves? The implication is that such moves
  #       wouldn't apply the "175 - score" bit, which would make their
  #       MoveHandlers do the opposite calculations to other moves with the same
  #       targets, but is this desirable?
  #=============================================================================
  def pbGetMoveScoreAgainstTarget
    # Predict whether the move will fail against the target
    if @trainer.has_skill_flag?("PredictMoveFailure") && pbPredictMoveFailureAgainstTarget
      PBDebug.log("     move will not affect #{@target.name}")
      return -1
    end
    # Score the move
    score = MOVE_BASE_SCORE
    if @trainer.has_skill_flag?("ScoreMoves")
      # Modify the score according to the move's effect against the target
      old_score = score
      score = Battle::AI::Handlers.apply_move_effect_against_target_score(@move.function,
         MOVE_BASE_SCORE, @move, @user, @target, self, @battle)
      PBDebug.log_score_change(score - old_score, "function code modifier (against target)")
      # Modify the score according to various other effects against the target
      score = Battle::AI::Handlers.apply_general_move_against_target_score_modifiers(
         score, @move, @user, @target, self, @battle)
    end
    # Add the score against the target to the overall score
    target_data = @move.pbTarget(@user.battler)
    if target_data.targets_foe && !@target.opposes?(@user) && @target.index != @user.index
      if score == MOVE_USELESS_SCORE
        PBDebug.log("     move is useless against #{@target.name}")
        return -1
      end
      # TODO: Is this reversal of the score okay?
      old_score = score
      score = 175 - score
      PBDebug.log_score_change(score - old_score, "score inverted (move targets ally but can target foe)")
    end
    return score
  end

  #=============================================================================
  # Make the final choice of which move to use depending on the calculated
  # scores for each move. Moves with higher scores are more likely to be chosen.
  #=============================================================================
  def pbChooseMove(choices)
    user_battler = @user.battler
    # If no moves can be chosen, auto-choose a move or Struggle
    if choices.length == 0
      @battle.pbAutoChooseMove(user_battler.index)
      PBDebug.log_ai("#{@user.name} will auto-use a move or Struggle")
      return
    end
    # Figure out useful information about the choices
    max_score = 0
    choices.each { |c| max_score = c[1] if max_score < c[1] }
    # Decide whether all choices are bad, and if so, try switching instead
    if @trainer.high_skill? && @user.can_switch_lax?
      badMoves = false
      if (max_score <= MOVE_FAIL_SCORE && user_battler.turnCount > 2) ||
         (max_score <= MOVE_USELESS_SCORE && user_battler.turnCount > 4)
        badMoves = true if pbAIRandom(100) < 80
      end
      if !badMoves && max_score <= MOVE_USELESS_SCORE && user_battler.turnCount >= 1
        badMoves = choices.none? { |c| user_battler.moves[c[0]].damagingMove? }
        badMoves = false if badMoves && pbAIRandom(100) < 10
      end
      if badMoves
        PBDebug.log_ai("#{@user.name} wants to switch due to terrible moves")
        return if pbEnemyShouldWithdrawEx?(true)
        PBDebug.log_ai("#{@user.name} won't switch after all")
      end
    end
    # Calculate a minimum score threshold and reduce all move scores by it
    threshold = (max_score * move_score_threshold.to_f).floor
    choices.each { |c| c[3] = [c[1] - threshold, 0].max }
    total_score = choices.sum { |c| c[3] }
    # Log the available choices
    if $INTERNAL
      PBDebug.log_ai("Move choices for #{@user.name}:")
      choices.each_with_index do |c, i|
        chance = sprintf("%5.1f", (c[3] > 0) ? 100.0 * c[3] / total_score : 0)
        log_msg = "   * #{chance}% to use #{user_battler.moves[c[0]].name}"
        log_msg += " (target #{c[2]})" if c[2] >= 0
        log_msg += ": score #{c[1]}"
        PBDebug.log(log_msg)
      end
    end
    # Pick a move randomly from choices weighted by their scores
    randNum = pbAIRandom(total_score)
    choices.each do |c|
      randNum -= c[3]
      next if randNum >= 0
      @battle.pbRegisterMove(user_battler.index, c[0], false)
      @battle.pbRegisterTarget(user_battler.index, c[2]) if c[2] >= 0
      break
    end
    # Log the result
    if @battle.choices[user_battler.index][2]
      move_name = @battle.choices[user_battler.index][2].name
      if @battle.choices[user_battler.index][3] >= 0
        PBDebug.log("   => will use #{move_name} (target #{@battle.choices[user_battler.index][3]})")
      else
        PBDebug.log("   => will use #{move_name}")
      end
    end
  end
end
