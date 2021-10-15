// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../interfaces/trader/ITraderPool.sol";
import "../interfaces/core/IPriceFeed.sol";
import "../interfaces/dex/IDEXAbstraction.sol";
import "../interfaces/core/IContractsRegistry.sol";
import "../interfaces/insurance/IInsurance.sol";

import "../libs/DecimalsConverter.sol";
import "../libs/TraderPoolHelper.sol";

import "../helpers/AbstractDependant.sol";
import "../core/Globals.sol";

abstract contract TraderPool is ITraderPool, ERC20Upgradeable, AbstractDependant {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using Math for uint256;
    using DecimalsConverter for uint256;
    using TraderPoolHelper for PoolParameters;

    IERC20 internal _dexeToken;
    IERC20 internal _daiToken;
    IPriceFeed internal _priceFeed;
    IDEXAbstraction internal _dexAbstraction;
    IInsurance internal _insurance;
    ICoreProperties internal _coreProperties;
    address internal _treasuryAddress;
    address internal _dividendsAddress;

    mapping(address => bool) public traderAdmins;

    PoolParameters public poolParameters;

    EnumerableSet.AddressSet internal _privateInvestors;
    EnumerableSet.AddressSet internal _investors;

    mapping(address => InvestorInfo) public investorsInfo;

    EnumerableSet.AddressSet internal _openPositions;

    modifier onlyTraderAdmin() {
        require(isTraderAdmin(_msgSender()), "TraderPool: msg.sender is not a trader admin");
        _;
    }

    function isTraderAdmin(address who) public view returns (bool) {
        return traderAdmins[who];
    }

    function isTrader(address who) public view returns (bool) {
        return poolParameters.trader == who;
    }

    function __TraderPool_init(
        string memory name,
        string memory symbol,
        string memory description,
        address trader,
        bool activePortfolio,
        bool privatePool,
        uint256 totalLPEmission,
        address baseToken,
        uint256 minimalInvestment,
        ICoreProperties.CommissionPeriod commissionPeriod,
        uint256 commissionPercentage
    ) public {
        __ERC20_init(name, symbol);

        poolParameters = PoolParameters(
            description,
            trader,
            activePortfolio,
            privatePool,
            totalLPEmission,
            baseToken,
            ERC20(baseToken).decimals(),
            minimalInvestment,
            commissionPeriod,
            commissionPercentage
        );

        traderAdmins[trader] = true;
    }

    function setDependencies(IContractsRegistry contractsRegistry)
        public
        virtual
        override
        onlyInjectorOrZero
    {
        _dexeToken = IERC20(contractsRegistry.getDEXEContract());
        _daiToken = IERC20(contractsRegistry.getDAIContract());
        _priceFeed = IPriceFeed(contractsRegistry.getPriceFeedContract());
        _dexAbstraction = IDEXAbstraction(contractsRegistry.getDEXAbstractionContract());
        _insurance = IInsurance(contractsRegistry.getInsuranceContract());
        _coreProperties = ICoreProperties(contractsRegistry.getCorePropertiesContract());
        _treasuryAddress = contractsRegistry.getTreasuryContract();
        _dividendsAddress = contractsRegistry.getDividendsContract();
    }

    function _transferBaseAndMintLP(uint256 totalBaseInPool, uint256 amountInBaseToInvest)
        internal
    {
        uint256 baseTokenDecimals = poolParameters.baseTokenDecimals;

        IERC20(poolParameters.baseToken).safeTransferFrom(
            _msgSender(),
            address(this),
            DecimalsConverter.convertFrom18(amountInBaseToInvest, baseTokenDecimals)
        );

        uint256 toMintLP = totalBaseInPool > 0
            ? (totalSupply() * amountInBaseToInvest) /
                totalBaseInPool.convertTo18(baseTokenDecimals)
            : amountInBaseToInvest;

        require(
            totalSupply() + toMintLP <= poolParameters.totalLPEmission,
            "TraderPool: minting more than emission allows"
        );

        _mint(_msgSender(), toMintLP);
    }

    function _investPassivePortfolio(uint256 amountInBaseToInvest) internal {
        (uint256 totalBase, , , ) = poolParameters.getPoolPrice(_openPositions, _priceFeed);
        _transferBaseAndMintLP(totalBase, amountInBaseToInvest);
    }

    function _investActivePortfolio(uint256 amountInBaseToInvest) internal {
        uint256 baseTokenDecimals = poolParameters.baseTokenDecimals;
        (
            uint256 totalBase,
            ,
            address[] memory positionTokens,
            uint256[] memory positionPricesInBase
        ) = poolParameters.getPoolPrice(_openPositions, _priceFeed);

        _transferBaseAndMintLP(totalBase, amountInBaseToInvest);

        IDEXAbstraction dexAbstraction = _dexAbstraction;
        address baseToken = poolParameters.baseToken;

        for (uint256 i = 0; i < positionTokens.length; i++) {
            uint256 tokensToExchange = (positionPricesInBase[i] *
                amountInBaseToInvest.convertFrom18(baseTokenDecimals)) / totalBase;

            dexAbstraction.exchangeTo(baseToken, positionTokens[i], tokensToExchange);
        }
    }

    function invest(uint256 amountInBaseToInvest) external virtual {
        require(
            !poolParameters.privatePool ||
                isTraderAdmin(_msgSender()) ||
                _privateInvestors.contains(_msgSender()),
            "TraderPool: msg.sender is not allowed to invest"
        );
        require(amountInBaseToInvest > 0, "TraderPool: zero investment");
        require(
            amountInBaseToInvest >= poolParameters.minimalInvestment,
            "TraderPool: underinvestment"
        );

        if (poolParameters.activePortfolio) {
            _investActivePortfolio(amountInBaseToInvest);
        } else {
            _investPassivePortfolio(amountInBaseToInvest);
        }

        if (!isTrader(_msgSender())) {
            _investors.add(_msgSender());

            require(
                _investors.length() <= _coreProperties.getMaximumPoolInvestors(),
                "TraderPool: max investors"
            );

            InvestorInfo memory oldInfo = investorsInfo[_msgSender()];

            investorsInfo[_msgSender()] = InvestorInfo(
                oldInfo.investedBase + amountInBaseToInvest,
                oldInfo.commissionUnlockEpoch == 0
                    ? _getNextCommissionEpoch(block.timestamp)
                    : oldInfo.commissionUnlockEpoch
            );
        }
    }

    function _getNextCommissionEpoch(uint256 timestamp) internal view returns (uint256) {
        return
            (timestamp - _coreProperties.getCommissionInitTimestamp()) /
            _coreProperties.getCommissionDuration(poolParameters.commissionPeriod) +
            1;
    }

    function _transferCommission(
        uint256 commission,
        address where,
        uint256 percentage
    ) private {
        _dexeToken.safeTransfer(where, (commission * percentage) / PERCENTAGE_100);
    }

    function _distributeCommission(uint256 baseTokensToDistribute, uint256 lpTokensToDistribute)
        internal
    {
        require(baseTokensToDistribute > 0, "TraderPool: no commission available");

        (
            uint256 dexeCommissionPercentage,
            uint256[] memory dexeIndividualPercentages
        ) = _coreProperties.getDEXECommissionPercentages();

        uint256 dexeLPCommission = (lpTokensToDistribute * dexeCommissionPercentage) /
            PERCENTAGE_100;
        uint256 dexeBaseCommission = ((baseTokensToDistribute * dexeCommissionPercentage) /
            PERCENTAGE_100).convertFrom18(poolParameters.baseTokenDecimals);
        uint256 dexeDexeCommission = _dexAbstraction.exchangeTo(
            poolParameters.baseToken,
            address(_dexeToken),
            dexeBaseCommission
        );

        _mint(poolParameters.trader, lpTokensToDistribute - dexeLPCommission);

        _transferCommission(
            dexeDexeCommission,
            address(_insurance),
            dexeIndividualPercentages[uint256(ICoreProperties.CommissionTypes.INSURANCE)]
        );
        _transferCommission(
            dexeDexeCommission,
            _treasuryAddress,
            dexeIndividualPercentages[uint256(ICoreProperties.CommissionTypes.TREASURY)]
        );
        _transferCommission(
            dexeDexeCommission,
            _dividendsAddress,
            dexeIndividualPercentages[uint256(ICoreProperties.CommissionTypes.DIVIDENDS)]
        );

        _insurance.receiveDexeFromPools();
    }

    function reinvestCommission(uint256 offset, uint256 limit) external virtual onlyTraderAdmin {
        require(_openPositions.length() == 0, "TraderPool: can't reinvest with opened positions");

        uint256 to = (offset + limit).min(_investors.length()).max(offset);
        uint256 totalSupply = totalSupply();

        uint256 allBaseCommission;
        uint256 allLPCommission;

        for (uint256 i = offset; i < to; i++) {
            address investor = _investors.at(i);
            uint256 nextCommissionEpoch = _getNextCommissionEpoch(block.timestamp);

            if (nextCommissionEpoch > investorsInfo[investor].commissionUnlockEpoch) {
                (
                    uint256 investorBaseAmount,
                    uint256 baseCommission,
                    uint256 lpCommission
                ) = _calculateCommissionOnReinvest(investor, totalSupply);

                investorsInfo[investor].investedBase = investorBaseAmount - baseCommission;
                investorsInfo[investor].commissionUnlockEpoch = nextCommissionEpoch;

                _burn(investor, lpCommission);

                allBaseCommission += baseCommission;
                allLPCommission += lpCommission;
            }
        }

        _distributeCommission(allBaseCommission, allLPCommission);
    }

    function _calculateCommission(
        uint256 investorBaseAmount,
        uint256 investorLPAmount,
        uint256 investedBaseAmount
    ) internal view returns (uint256 baseCommission, uint256 lpCommission) {
        if (investorBaseAmount > investedBaseAmount) {
            baseCommission =
                ((investorBaseAmount - investedBaseAmount) * poolParameters.commissionPercentage) /
                PERCENTAGE_100;

            lpCommission = (investorLPAmount * baseCommission) / investorBaseAmount;
        }
    }

    function _calculateCommissionOnReinvest(address investor, uint256 oldTotalSupply)
        internal
        view
        returns (
            uint256 investorBaseAmount,
            uint256 baseCommission,
            uint256 lpCommission
        )
    {
        uint256 baseTokenBalance = ERC20(poolParameters.baseToken)
            .balanceOf(address(this))
            .convertTo18(poolParameters.baseTokenDecimals);

        investorBaseAmount = (baseTokenBalance * balanceOf(investor)) / oldTotalSupply;

        (baseCommission, lpCommission) = _calculateCommission(
            investorBaseAmount,
            balanceOf(investor),
            investorsInfo[investor].investedBase
        );
    }

    function _calculateCommissionOnDivest(
        address investor,
        uint256 investorBaseAmount,
        uint256 amountLP
    ) internal view returns (uint256 baseCommission, uint256 lpCommission) {
        uint256 investedBaseConverted = (investorsInfo[investor].investedBase * amountLP) /
            balanceOf(investor);

        (baseCommission, lpCommission) = _calculateCommission(
            investorBaseAmount,
            amountLP,
            investedBaseConverted
        );
    }

    function _divestInvestor(uint256 amountLP) internal {
        IERC20 baseToken = IERC20(poolParameters.baseToken);
        IDEXAbstraction dexAbstraction = _dexAbstraction;

        uint256 totalSupply = totalSupply();

        uint256 length = _openPositions.length();
        uint256 investorBaseAmount = (baseToken.balanceOf(address(this)) * amountLP) / totalSupply;

        for (uint256 i = 0; i < length; i++) {
            ERC20 positionToken = ERC20(_openPositions.at(i));

            uint256 positionAmount = (positionToken.balanceOf(address(this)) * amountLP) /
                totalSupply;

            investorBaseAmount += dexAbstraction.exchangeTo(
                address(positionToken),
                address(baseToken),
                positionAmount
            );
        }

        investorBaseAmount = investorBaseAmount.convertTo18(poolParameters.baseTokenDecimals);

        (uint256 baseCommission, uint256 lpCommission) = _calculateCommissionOnDivest(
            _msgSender(),
            investorBaseAmount,
            amountLP
        );

        _burn(_msgSender(), amountLP);

        baseToken.safeTransfer(
            _msgSender(),
            (investorBaseAmount - baseCommission).convertFrom18(poolParameters.baseTokenDecimals)
        );

        if (baseCommission > 0) {
            _distributeCommission(baseCommission, lpCommission);
        }

        _updateFromInvestor(_msgSender(), amountLP);
    }

    function _divestTrader(uint256 amountLP) internal {
        IERC20 baseToken = IERC20(poolParameters.baseToken);

        uint256 baseTokenBalance = baseToken.balanceOf(address(this));
        uint256 traderBaseAmount = (baseTokenBalance * amountLP) / totalSupply();

        _burn(_msgSender(), amountLP);

        baseToken.safeTransfer(_msgSender(), traderBaseAmount);
    }

    function divest(uint256 amountLP) external virtual {
        require(
            !isTrader(_msgSender()) || _openPositions.length() == 0,
            "TraderPool: can't divest"
        );
        require(amountLP <= balanceOf(_msgSender()), "TraderPool: can't divest that amount");

        if (!isTrader(_msgSender())) {
            _divestInvestor(amountLP);
        } else {
            _divestTrader(amountLP);
        }
    }

    function _checkLeverage(uint256 addInDAI) internal view {
        (uint256 totalBaseInDAI, uint256 positionsInDAI) = poolParameters.getPoolInfoInToken(
            _openPositions,
            _priceFeed,
            address(_daiToken)
        );

        (uint256 threshold, uint256 slope) = _coreProperties.getTraderLeverageParams();

        uint256 maxTraderVolumeInDAI = TraderPoolHelper.getMaxTraderLeverage(
            (totalBaseInDAI * balanceOf(poolParameters.trader)) / totalSupply(),
            threshold,
            slope
        );

        require(
            addInDAI + positionsInDAI <= maxTraderVolumeInDAI,
            "TraderPool: exchange exceeds leverage"
        );
    }

    // TODO check approvals
    function exchange(
        address from,
        address to,
        uint256 amount
    ) external virtual onlyTraderAdmin {
        require(
            from == poolParameters.baseToken || _openPositions.contains(from),
            "TraderPool: invalid exchange address"
        );
        require(
            amount <= ERC20(from).balanceOf(address(this)),
            "TraderPool: invalid exchange amount"
        );

        uint256 convertedAmount = amount.convertFrom18(ERC20(from).decimals());

        if (from == poolParameters.baseToken) {
            _checkLeverage(_priceFeed.getPriceIn(from, address(_daiToken), convertedAmount));
            _openPositions.add(to);
        } else if (to != poolParameters.baseToken) {
            _checkLeverage(0);
            _openPositions.add(to);
        }

        _dexAbstraction.exchangeTo(from, to, convertedAmount);

        if (ERC20(from).balanceOf(address(this)) == 0) {
            _openPositions.remove(from);
        }
    }

    function _updateFromInvestor(address investor, uint256 amount)
        internal
        returns (uint256 baseTransfer)
    {
        baseTransfer = (investorsInfo[investor].investedBase * amount) / balanceOf(investor);

        if (amount == balanceOf(investor)) {
            _investors.remove(investor);
            investorsInfo[investor].commissionUnlockEpoch = 0;
        }

        investorsInfo[investor].investedBase -= baseTransfer;
    }

    function _updateToInvestor(address investor, uint256 amount) internal {
        if (balanceOf(investor) == 0) {
            _investors.add(investor);
            investorsInfo[investor].commissionUnlockEpoch = _getNextCommissionEpoch(
                block.timestamp
            );

            require(
                _investors.length() <= _coreProperties.getMaximumPoolInvestors(),
                "TraderPool: max investors"
            );
        }

        investorsInfo[investor].investedBase += amount;
    }

    /// @notice if trader transfers tokens to an investor, we will count them as "earned" and add to the commission calculation
    /// TODO check LP transfer to this address
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        require(amount > 0, "TraderPool: 0 transfer");
        require(
            !poolParameters.privatePool || isTraderAdmin(to) || _privateInvestors.contains(to),
            "TraderPool: prohibited transfer"
        );

        if (from != address(0) && to != address(0)) {
            uint256 baseTransfer; // intended to be zero if sender is a trader

            if (!isTrader(from)) {
                baseTransfer = _updateFromInvestor(from, amount);
            }

            if (!isTrader(to)) {
                _updateFromInvestor(from, baseTransfer);
            }
        }
    }
}
