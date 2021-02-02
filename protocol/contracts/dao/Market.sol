/*
    Copyright 2020 Dynamic Dollar Devs, based on the works of the Empty Set Squad

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
*/

pragma solidity ^0.5.17;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./Curve.sol";
import "./Comptroller.sol";
import "../Constants.sol";

contract Market is Comptroller, Curve {
    using SafeMath for uint256;

    bytes32 private constant FILE = "Market";

    event CouponExpiration(uint256 indexed epoch, uint256 couponsExpired, uint256 lessRedeemable, uint256 lessDebt, uint256 newBonded);
    event CouponPurchase(address indexed account, uint256 indexed epoch, uint256 dollarAmount, uint256 couponAmount);
    event CouponRedemption(address indexed account, uint256 indexed epoch, uint256 amount, uint256 couponAmount);
    event CouponBurn(address indexed account, uint256 indexed epoch, uint256 couponAmount);
    event CouponTransfer(address indexed from, address indexed to, uint256 indexed epoch, uint256 value);
    event CouponApproval(address indexed owner, address indexed spender, uint256 value);

    function step() internal {
        // Expire prior coupons
        for (uint256 i = 0; i < expiringCoupons(epoch()); i++) {
            expireCouponsForEpoch(expiringCouponsAtIndex(epoch(), i));
        }

        // Record expiry for current epoch's coupons
        uint256 expirationEpoch = epoch().add(Constants.getCouponExpiration());
        initializeCouponsExpiration(epoch(), expirationEpoch);
    }

    function expireCouponsForEpoch(uint256 epoch) private {
        uint256 couponsForEpoch = outstandingCoupons(epoch);
        (uint256 lessRedeemable, uint256 newBonded) = (0, 0);

        eliminateOutstandingCoupons(epoch);

        uint256 totalRedeemable = totalRedeemable();
        uint256 totalCoupons = totalCoupons();
        if (totalRedeemable > totalCoupons) {
            lessRedeemable = totalRedeemable.sub(totalCoupons);
            burnRedeemable(lessRedeemable);
            (, newBonded) = increaseSupply(lessRedeemable);
        }

        emit CouponExpiration(epoch, couponsForEpoch, lessRedeemable, 0, newBonded);
    }

    function couponPremium(uint256 amount) public view returns (uint256) {
        return calculateCouponPremium(dollar().totalSupply(), totalDebt(), amount);
    }

    function couponRedemptionPenalty(uint256 couponEpoch, uint256 couponAmount) public view returns (uint256) {
        uint timeIntoEpoch = block.timestamp % Constants.getEpochStrategy().period;
        uint couponAge = epoch().sub(couponEpoch, "Market: Future couponEpoch");

        if (couponAge >= Constants.getCouponExpiration()) {
            return 0;
        }

        uint couponEpochDecay = Constants.getCouponRedemptionPenaltyDecay() * (Constants.getCouponExpiration() - couponAge) / Constants.getCouponExpiration();

        if (timeIntoEpoch >= couponEpochDecay) {
            return 0;
        }

        Decimal.D256 memory couponEpochInitialPenalty = Constants.getInitialCouponRedemptionPenalty().div(Decimal.D256({value: Constants.getCouponExpiration() })).mul(Decimal.D256({value: Constants.getCouponExpiration() - couponAge}));

        Decimal.D256 memory couponEpochDecayedPenalty = couponEpochInitialPenalty.div(Decimal.D256({value: couponEpochDecay})).mul(Decimal.D256({value: couponEpochDecay - timeIntoEpoch}));

        return Decimal.D256({value: couponAmount}).mul(couponEpochDecayedPenalty).value;
    }

    function migrateCoupons(uint256 couponEpoch) external {
        require(balanceOfCouponUnderlying(msg.sender, couponEpoch) == 0, "Market: Already migrated");

        uint256 balanceOfCoupons = _state.accounts[msg.sender].coupons[couponEpoch];
        uint256 couponUnderlying = balanceOfCoupons.div(2);

        if (outstandingCoupons(couponEpoch) == 0) {
            // coupons have expired
            _state.accounts[msg.sender].coupons[couponEpoch] = 0;
        } else {
            // coupons have not expired
            decrementBalanceOfCoupons(msg.sender, couponEpoch, couponUnderlying, "Market: Insufficient coupon balance");
        }

        incrementBalanceOfCouponUnderlying(msg.sender, couponEpoch, couponUnderlying);

        emit CouponRedemption(msg.sender, couponEpoch, 0, couponUnderlying);
        emit CouponPurchase(msg.sender, couponEpoch, couponUnderlying, 0);
    }

    function purchaseCoupons(uint256 amount) external returns (uint256) {
        Require.that(
            amount > 0,
            FILE,
            "Must purchase non-zero amount"
        );

        Require.that(
            totalDebt() >= amount,
            FILE,
            "Not enough debt"
        );

        uint256 epoch = epoch();

        // coupon total (deposit + premium)
        uint256 balanceOfCoupons = amount.add(couponPremium(amount));

        // split total by 1/2
        uint256 couponUnderlying = balanceOfCoupons.div(2);

        // 1/2 can expire
        incrementBalanceOfCoupons(msg.sender, epoch, couponUnderlying);

        // 1/2 can always be reclaimed
        incrementBalanceOfCouponUnderlying(msg.sender, epoch, couponUnderlying);

        burnFromAccount(msg.sender, amount);

        emit CouponPurchase(msg.sender, epoch, amount, couponUnderlying);

        return couponUnderlying;
    }

    function redeemCoupons(uint256 couponEpoch, uint256 amount) external {
        require(_state13.price.greaterThan(Decimal.one()), "Market: not in expansion");
        require(epoch().sub(couponEpoch) >= 2, "Market: Too early to redeem");
        require(amount != 0, "Market: Amount too low");

        uint256 underlying = balanceOfCouponUnderlying(msg.sender, couponEpoch);
        require(underlying >= amount, "Market: Insufficient coupon underlying balance");

        uint256 couponAmount;
        if (outstandingCoupons(couponEpoch) == 0) {
            // coupons have expired
            _state.accounts[msg.sender].coupons[couponEpoch] = 0;
        } else {
            // coupons have not expired
            couponAmount = _state.accounts[msg.sender].coupons[couponEpoch]
                .mul(amount).div(underlying, "Market: No underlying");
        }

        uint256 totalAmount = couponAmount.add(amount);

        // penalty burn will be applied to premium and underlying
        uint256 burnAmount = couponRedemptionPenalty(couponEpoch, totalAmount);

        if (couponAmount != 0) {
            decrementBalanceOfCoupons(msg.sender, couponEpoch, couponAmount, "Market: Insufficient coupon balance");

            // reduce premium by redemption penalty
            couponAmount = couponAmount - burnAmount.mul(couponAmount).div(totalAmount);
        }

        decrementBalanceOfCouponUnderlying(msg.sender, couponEpoch, amount, "Market: Insufficient coupon underlying balance");

        // reduce underlying by redemption penalty
        amount = amount - burnAmount.mul(amount).div(totalAmount);

        redeemToAccount(msg.sender, amount, couponAmount);

        if (burnAmount != 0) {
            emit CouponBurn(msg.sender, couponEpoch, burnAmount);
        }

        emit CouponRedemption(msg.sender, couponEpoch, amount, couponAmount);
    }

    function redeemCoupons(uint256 couponEpoch, uint256 amount, uint256 minOutput) external {
        require(_state13.price.greaterThan(Decimal.one()), "Market: not in expansion");
        require(epoch().sub(couponEpoch) >= 2, "Market: Too early to redeem");
        require(amount != 0, "Market: Amount too low");

        uint256 underlying = balanceOfCouponUnderlying(msg.sender, couponEpoch);
        require(underlying >= amount, "Market: Insufficient coupon underlying balance");

        uint256 couponAmount;
        if (outstandingCoupons(couponEpoch) == 0) {
            // coupons have expired
            _state.accounts[msg.sender].coupons[couponEpoch] = 0;
        } else {
            // coupons have not expired
            couponAmount = _state.accounts[msg.sender].coupons[couponEpoch]
                .mul(amount).div(underlying, "Market: No underlying");
        }

        uint256 totalAmount = couponAmount.add(amount);

        // penalty burn will be applied to premium and underlying
        uint256 burnAmount = couponRedemptionPenalty(couponEpoch, totalAmount);

        if (couponAmount != 0) {
            decrementBalanceOfCoupons(msg.sender, couponEpoch, couponAmount, "Market: Insufficient coupon balance");

            // reduce premium by redemption penalty
            couponAmount = couponAmount - burnAmount.mul(couponAmount).div(totalAmount);
        }

        decrementBalanceOfCouponUnderlying(msg.sender, couponEpoch, amount, "Market: Insufficient coupon underlying balance");

        // reduce underlying by redemption penalty
        amount = amount - burnAmount.mul(amount).div(totalAmount);

        Require.that(
            couponAmount.add(amount) >= minOutput,
            FILE,
            "Insufficient output amount"
        );

        redeemToAccount(msg.sender, amount, couponAmount);

        if (burnAmount != 0) {
            emit CouponBurn(msg.sender, couponEpoch, burnAmount);
        }

        emit CouponRedemption(msg.sender, couponEpoch, amount, couponAmount);
    }

    function approveCoupons(address spender, uint256 amount) external {
        require(spender != address(0), "Market: Coupon approve to the zero address");

        updateAllowanceCoupons(msg.sender, spender, amount);

        emit CouponApproval(msg.sender, spender, amount);
    }

    function transferCoupons(address sender, address recipient, uint256 epoch, uint256 amount) external {
        require(sender != address(0), "Market: Coupon transfer from the zero address");
        require(recipient != address(0), "Market: Coupon transfer to the zero address");
        require(amount != 0, "Market: Amount too low");

        uint256 underlying = balanceOfCouponUnderlying(sender, epoch);
        require(underlying >= amount, "Market: Insufficient coupon underlying balance");

        uint256 couponAmount;
        if (outstandingCoupons(epoch) == 0) {
            // coupons have expired
            _state.accounts[sender].coupons[epoch] = 0;
        } else {
            // coupons have not expired
            couponAmount = _state.accounts[sender].coupons[epoch]
                .mul(amount).div(underlying, "Market: No underlying");
        }

        decrementBalanceOfCouponUnderlying(sender, epoch, amount, "Market: Insufficient coupon underlying balance");
        incrementBalanceOfCouponUnderlying(recipient, epoch, amount);

        if (couponAmount != 0) {
            decrementBalanceOfCoupons(sender, epoch, couponAmount, "Market: Insufficient coupon balance");
            incrementBalanceOfCoupons(recipient, epoch, couponAmount);
        }

        if (msg.sender != sender && allowanceCoupons(sender, msg.sender) != uint256(-1)) {
            decrementAllowanceCoupons(sender, msg.sender, amount, "Market: Insufficient coupon approval");
        }

        emit CouponTransfer(sender, recipient, epoch, amount);
    }
}
