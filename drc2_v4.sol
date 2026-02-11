// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {
    // slots:
    // 0 lastTimestamp
    // 1 currentBidFee
    // 2 currentAskFee
    // 3 fairPrice (WAD)
    // 4 ewmaMis
    // 5 ewmaVol
    // 6 ewmaLoss
    // 7 ewmaTailLoss
    // 8 lastSpot
    // 9 mode (0 calm, 1 stress)
    // 10 stressScore

    // Frozen champion core.
    uint256 private constant TIGHT_BAND_BPS = 26;
    uint256 private constant INIT_FEE_CENTI_BPS = 2500;
    uint256 private constant TIGHT_FEE_CENTI_BPS = 2788;
    uint256 private constant UNDERCUT_CENTI_BPS = 1000;
    uint256 private constant BUFFER_CENTI_BPS = 35;

    uint256 private constant BASE_ALPHA_NEW_PCT = 19;
    uint256 private constant QUIET_ALPHA_NEW_PCT = 15;
    uint256 private constant QUIET_MIS_BPS = 15;
    uint256 private constant FAST_ALPHA_NEW_PCT = 19;
    uint256 private constant FAST_MIS_BPS = 9999;
    uint256 private constant MAX_ALPHA_NEW_PCT = 19;

    uint256 private constant JUMP_UP_BPS = 400;
    uint256 private constant JUMP_DOWN_BPS = 400;

    // Robust overlay parameters.
    uint256 private constant EWMA_MIS_NEW_PCT = 20;
    uint256 private constant EWMA_VOL_NEW_PCT = 20;
    uint256 private constant EWMA_LOSS_NEW_PCT = 10;
    uint256 private constant EWMA_TAIL_NEW_PCT = 12;

    uint256 private constant STRESS_ENTER_BPS = 95;
    uint256 private constant STRESS_EXIT_BPS = 70;

    uint256 private constant AMBIGUITY_PCT = 25;
    uint256 private constant VOL_WEIGHT_PCT = 10;
    uint256 private constant ADV_REPLAY_WEIGHT_PCT = 12;

    uint256 private constant CVAR_TAIL_TRIGGER_BPS = 4;
    uint256 private constant CVAR_TAIL_WEIGHT_PCT = 130;

    uint256 private constant STRESS_UNDERCUT_CUT_CENTI_BPS = 55;
    uint256 private constant STRESS_BUFFER_ADD_CENTI_BPS = 12;
    uint256 private constant STRESS_BAND_CUT_BPS = 1;

    uint256 private constant PANIC_SCORE_BPS = 130;
    uint256 private constant PANIC_BUFFER_ADD_CENTI_BPS = 20;

    function centiBpsToWad(uint256 centiBps) internal pure returns (uint256) {
        return (centiBps * BPS) / 100;
    }

    function afterInitialize(uint256 initialX, uint256 initialY)
        external
        override
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 p0 = initialX == 0 ? WAD : wdiv(initialY, initialX);
        slots[0] = type(uint256).max;
        slots[3] = p0;
        slots[8] = p0;
        slots[9] = 0;
        slots[10] = 0;

        uint256 initFee = centiBpsToWad(INIT_FEE_CENTI_BPS);
        bidFee = initFee;
        askFee = initFee;
        slots[1] = bidFee;
        slots[2] = askFee;
    }

    function afterSwap(TradeInfo calldata trade)
        external
        override
        returns (uint256 bidFee, uint256 askFee)
    {
        uint256 lastTs = slots[0];
        uint256 prevBid = slots[1];
        uint256 prevAsk = slots[2];
        uint256 fair = slots[3];

        uint256 ewmaMis = slots[4];
        uint256 ewmaVol = slots[5];
        uint256 ewmaLoss = slots[6];
        uint256 ewmaTail = slots[7];
        uint256 lastSpot = slots[8];
        uint256 mode = slots[9];
        uint256 stressScore = slots[10];

        uint256 rx = trade.reserveX;
        uint256 ry = trade.reserveY;
        uint256 spot = rx == 0 ? 0 : wdiv(ry, rx);

        // Adversarial replay proxy: EWMA of realized downside edge.
        if (fair != 0 && trade.amountY != 0) {
            uint256 fairNotional = wmul(trade.amountX, fair);
            uint256 lossRel = 0;
            if (trade.isBuy) {
                if (trade.amountY < fairNotional) {
                    lossRel = wdiv(fairNotional - trade.amountY, trade.amountY);
                }
            } else {
                if (trade.amountY > fairNotional) {
                    lossRel = wdiv(trade.amountY - fairNotional, trade.amountY);
                }
            }

            uint256 tailRel = 0;
            uint256 tailTrig = bpsToWad(CVAR_TAIL_TRIGGER_BPS);
            if (lossRel > tailTrig) {
                tailRel = lossRel - tailTrig;
            }

            if (ewmaLoss == 0) ewmaLoss = lossRel;
            else ewmaLoss = (ewmaLoss * (100 - EWMA_LOSS_NEW_PCT) + lossRel * EWMA_LOSS_NEW_PCT) / 100;

            if (ewmaTail == 0) ewmaTail = tailRel;
            else ewmaTail = (ewmaTail * (100 - EWMA_TAIL_NEW_PCT) + tailRel * EWMA_TAIL_NEW_PCT) / 100;
        }

        bool isNewStep = trade.timestamp != lastTs;
        if (isNewStep) {
            uint256 gamma = trade.isBuy ? (WAD - prevBid) : (WAD - prevAsk);
            uint256 fairCandidate = fair;
            if (gamma != 0 && spot != 0) {
                fairCandidate = trade.isBuy ? wmul(spot, gamma) : wdiv(spot, gamma);
            }

            uint256 rel = 0;
            if (fair != 0) {
                rel = wdiv(absDiff(fairCandidate, fair), fair);

                uint256 upCap = bpsToWad(JUMP_UP_BPS);
                uint256 downCap = bpsToWad(JUMP_DOWN_BPS);
                if (fairCandidate > fair && rel > upCap) {
                    fairCandidate = fair + wmul(fair, upCap);
                    rel = upCap;
                } else if (fairCandidate < fair && rel > downCap) {
                    fairCandidate = fair - wmul(fair, downCap);
                    rel = downCap;
                }
            }

            uint256 alpha = BASE_ALPHA_NEW_PCT;
            if (rel <= bpsToWad(QUIET_MIS_BPS) && QUIET_ALPHA_NEW_PCT < alpha) {
                alpha = QUIET_ALPHA_NEW_PCT;
            }
            if (rel >= bpsToWad(FAST_MIS_BPS) && FAST_ALPHA_NEW_PCT > alpha) {
                alpha = FAST_ALPHA_NEW_PCT;
            }
            if (alpha > MAX_ALPHA_NEW_PCT) alpha = MAX_ALPHA_NEW_PCT;

            fair = (fair * (100 - alpha) + fairCandidate * alpha) / 100;
            slots[0] = trade.timestamp;
            slots[3] = fair;
        }

        if (spot == 0 || fair == 0) {
            bidFee = bpsToWad(30);
            askFee = bpsToWad(30);
            slots[1] = bidFee;
            slots[2] = askFee;
            slots[4] = ewmaMis;
            slots[5] = ewmaVol;
            slots[6] = ewmaLoss;
            slots[7] = ewmaTail;
            if (spot != 0 && isNewStep) slots[8] = spot;
            slots[9] = mode;
            slots[10] = stressScore;
            return (bidFee, askFee);
        }

        uint256 mis = wdiv(absDiff(spot, fair), fair);
        if (isNewStep) {
            if (ewmaMis == 0) ewmaMis = mis;
            else ewmaMis = (ewmaMis * (100 - EWMA_MIS_NEW_PCT) + mis * EWMA_MIS_NEW_PCT) / 100;

            uint256 vol = 0;
            if (lastSpot != 0) {
                vol = wdiv(absDiff(spot, lastSpot), lastSpot);
            }
            if (ewmaVol == 0) ewmaVol = vol;
            else ewmaVol = (ewmaVol * (100 - EWMA_VOL_NEW_PCT) + vol * EWMA_VOL_NEW_PCT) / 100;

            uint256 worst = ewmaMis > ewmaVol ? ewmaMis : ewmaVol;
            uint256 robustCore = (ewmaMis * (100 - AMBIGUITY_PCT) + worst * AMBIGUITY_PCT) / 100;
            uint256 cvarProxy = ewmaLoss + (ewmaTail * CVAR_TAIL_WEIGHT_PCT) / 100;

            stressScore = robustCore;
            stressScore += (ewmaVol * VOL_WEIGHT_PCT) / 100;
            stressScore += (cvarProxy * ADV_REPLAY_WEIGHT_PCT) / 100;

            uint256 enter = bpsToWad(STRESS_ENTER_BPS);
            uint256 exitLevel = bpsToWad(STRESS_EXIT_BPS);
            if (mode == 0) {
                if (stressScore >= enter) mode = 1;
            } else if (stressScore <= exitLevel) {
                mode = 0;
            }

            lastSpot = spot;
        }

        uint256 tightBandBps = TIGHT_BAND_BPS;
        uint256 undercut = centiBpsToWad(UNDERCUT_CENTI_BPS);
        uint256 buffer = centiBpsToWad(BUFFER_CENTI_BPS);

        if (mode == 1) {
            uint256 cut = centiBpsToWad(STRESS_UNDERCUT_CUT_CENTI_BPS);
            undercut = undercut > cut ? undercut - cut : 0;
            buffer += centiBpsToWad(STRESS_BUFFER_ADD_CENTI_BPS);
            if (tightBandBps > STRESS_BAND_CUT_BPS) tightBandBps -= STRESS_BAND_CUT_BPS;
            else tightBandBps = 1;

            if (stressScore >= bpsToWad(PANIC_SCORE_BPS)) {
                buffer += centiBpsToWad(PANIC_BUFFER_ADD_CENTI_BPS);
            }
        }

        if (mis <= bpsToWad(tightBandBps)) {
            uint256 tight = centiBpsToWad(TIGHT_FEE_CENTI_BPS);
            bidFee = tight;
            askFee = tight;
        } else {
            uint256 gammaBase = WAD - bpsToWad(30);
            uint256 gammaBaseSq = wmul(gammaBase, gammaBase);

            if (spot > fair) {
                uint256 gammaReq = wdiv(fair, spot);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                bidFee = clampFee(req + buffer);

                uint256 gammaMatch = wdiv(wmul(spot, gammaBaseSq), fair);
                uint256 askRaw = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
                askFee = askRaw > undercut ? askRaw - undercut : 0;
            } else {
                uint256 gammaReq = wdiv(spot, fair);
                uint256 req = gammaReq >= WAD ? 0 : (WAD - gammaReq);
                askFee = clampFee(req + buffer);

                uint256 gammaMatch = wdiv(wmul(fair, gammaBaseSq), spot);
                uint256 bidRaw = gammaMatch >= WAD ? 0 : (WAD - gammaMatch);
                bidFee = bidRaw > undercut ? bidRaw - undercut : 0;
            }
        }

        bidFee = clampFee(bidFee);
        askFee = clampFee(askFee);
        slots[1] = bidFee;
        slots[2] = askFee;
        slots[4] = ewmaMis;
        slots[5] = ewmaVol;
        slots[6] = ewmaLoss;
        slots[7] = ewmaTail;
        slots[8] = lastSpot;
        slots[9] = mode;
        slots[10] = stressScore;
    }

    function getName() external pure override returns (string memory) {
        return "drc2_v4";
    }
}
