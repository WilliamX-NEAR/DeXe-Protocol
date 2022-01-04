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
import "../interfaces/core/IContractsRegistry.sol";
import "../interfaces/insurance/IInsurance.sol";

import "../libs/TraderPool/TraderPoolPrice.sol";
import "../libs/TraderPool/TraderPoolLeverage.sol";
import "../libs/TraderPool/TraderPoolCommission.sol";
import "../libs/TraderPool/TraderPoolView.sol";
import "../libs/DecimalsConverter.sol";
import "../libs/MathHelper.sol";

import "../helpers/AbstractDependant.sol";
import "../core/Globals.sol";

abstract contract TraderPool is ITraderPool, ERC20Upgradeable, AbstractDependant {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using Math for uint256;
    using DecimalsConverter for uint256;
    using TraderPoolPrice for PoolParameters;
    using TraderPoolPrice for address;
    using TraderPoolLeverage for PoolParameters;
    using TraderPoolCommission for PoolParameters;
    using TraderPoolView for PoolParameters;
    using MathHelper for uint256;

    IERC20 internal _dexeToken;
    IPriceFeed public override priceFeed;
    ICoreProperties public override coreProperties;

    mapping(address => bool) public traderAdmins;

    PoolParameters public poolParameters;

    EnumerableSet.AddressSet internal _privateInvestors;
    EnumerableSet.AddressSet internal _investors;

    mapping(address => InvestorInfo) public investorsInfo;

    EnumerableSet.AddressSet internal _openPositions;

    mapping(address => mapping(uint256 => uint256)) internal _investsInBlocks; // user => block => LP amount

    modifier onlyTraderAdmin() {
        require(isTraderAdmin(_msgSender()), "TP: not a trader admin");
        _;
    }

    modifier onlyTrader() {
        require(isTrader(_msgSender()), "TP: not a trader");
        _;
    }

    function _isPrivateInvestor(address who) internal view returns (bool) {
        return _privateInvestors.contains(who);
    }

    function isTraderAdmin(address who) public view override returns (bool) {
        return traderAdmins[who];
    }

    function isTrader(address who) public view override returns (bool) {
        return poolParameters.trader == who;
    }

    function __TraderPool_init(
        string calldata name,
        string calldata symbol,
        PoolParameters calldata _poolParameters
    ) public onlyInitializing {
        __ERC20_init(name, symbol);

        poolParameters = _poolParameters;
        traderAdmins[_poolParameters.trader] = true;
    }

    function setDependencies(IContractsRegistry contractsRegistry)
        public
        virtual
        override
        dependant
    {
        _dexeToken = IERC20(contractsRegistry.getDEXEContract());
        priceFeed = IPriceFeed(contractsRegistry.getPriceFeedContract());
        coreProperties = ICoreProperties(contractsRegistry.getCorePropertiesContract());
    }

    function modifyAdmins(address[] calldata admins, bool add) external override onlyTraderAdmin {
        for (uint256 i = 0; i < admins.length; i++) {
            traderAdmins[admins[i]] = add;
        }

        traderAdmins[poolParameters.trader] = true;
    }

    function modifyPrivateInvestors(address[] calldata privateInvestors, bool add)
        external
        override
        onlyTraderAdmin
    {
        for (uint256 i = 0; i < privateInvestors.length; i++) {
            _privateInvestors.add(privateInvestors[i]);

            if (!add && balanceOf(privateInvestors[i]) == 0) {
                _privateInvestors.remove(privateInvestors[i]);
            }
        }
    }

    function changePoolParameters(
        string calldata descriptionURL,
        bool privatePool,
        uint256 totalLPEmission,
        uint256 minimalInvestment
    ) external override onlyTraderAdmin {
        require(
            totalLPEmission == 0 || totalEmission() <= totalLPEmission,
            "TP: wrong emission supply"
        );
        require(
            !privatePool || (privatePool && _investors.length() == 0),
            "TP: pool is not empty"
        );

        poolParameters.descriptionURL = descriptionURL;
        poolParameters.privatePool = privatePool;
        poolParameters.totalLPEmission = totalLPEmission;
        poolParameters.minimalInvestment = minimalInvestment;
    }

    function totalOpenPositions() external view override returns (uint256) {
        return _openPositions.length();
    }

    function totalInvestors() external view override returns (uint256) {
        return _investors.length();
    }

    function proposalPoolAddress() external view virtual override returns (address);

    function totalEmission() public view virtual override returns (uint256);

    function _transferBaseAndMintLP(
        address baseHolder,
        uint256 totalBaseInPool,
        uint256 amountInBaseToInvest
    ) internal {
        IERC20(poolParameters.baseToken).safeTransferFrom(
            baseHolder,
            address(this),
            amountInBaseToInvest.convertFrom18(poolParameters.baseTokenDecimals)
        );

        uint256 toMintLP = amountInBaseToInvest;

        if (totalBaseInPool > 0) {
            toMintLP = toMintLP.ratio(totalSupply(), totalBaseInPool);
        }

        require(
            poolParameters.totalLPEmission == 0 ||
                totalEmission() + toMintLP <= poolParameters.totalLPEmission,
            "TP: minting more than emission allows"
        );

        _investsInBlocks[_msgSender()][block.number] += toMintLP;
        _mint(_msgSender(), toMintLP);
    }

    function getLeverageInfo() external view returns (LeverageInfo memory leverageInfo) {
        return poolParameters.getLeverageInfo(_openPositions);
    }

    function getInvestTokens(uint256 amountInBaseToInvest)
        external
        view
        override
        returns (Receptions memory receptions)
    {
        return poolParameters.getInvestTokens(_openPositions, amountInBaseToInvest);
    }

    function _invest(
        address baseHolder,
        uint256 amountInBaseToInvest,
        uint256[] calldata minPositionsOut
    ) internal {
        IPriceFeed _priceFeed = priceFeed;
        (
            uint256 totalBase,
            ,
            address[] memory positionTokens,
            uint256[] memory positionPricesInBase
        ) = poolParameters.getNormalizedPoolPrice(_openPositions);

        address baseToken = poolParameters.baseToken;

        if (!isTrader(_msgSender())) {
            poolParameters.checkLeverage(_openPositions, amountInBaseToInvest);
        }

        _transferBaseAndMintLP(baseHolder, totalBase, amountInBaseToInvest);

        for (uint256 i = 0; i < positionTokens.length; i++) {
            _priceFeed.normalizedExchangeFromExact(
                baseToken,
                positionTokens[i],
                positionPricesInBase[i].ratio(amountInBaseToInvest, totalBase),
                new address[](0),
                minPositionsOut[i]
            );
        }

        if (!isTrader(_msgSender())) {
            _updateTo(_msgSender(), amountInBaseToInvest);
        }
    }

    function invest(uint256 amountInBaseToInvest, uint256[] calldata minPositionsOut)
        public
        virtual
        override
    {
        require(amountInBaseToInvest > 0, "TP: zero investment");
        require(amountInBaseToInvest >= poolParameters.minimalInvestment, "TP: underinvestment");

        _invest(_msgSender(), amountInBaseToInvest, minPositionsOut);
    }

    function _sendDexeCommission(
        uint256 dexeCommission,
        uint256[] memory poolPercentages,
        address[3] memory commissionReceivers
    ) internal {
        uint256[] memory receivedCommissions = new uint256[](3);
        uint256 dexeDecimals = ERC20(address(_dexeToken)).decimals();

        for (uint256 i = 0; i < commissionReceivers.length; i++) {
            receivedCommissions[i] = dexeCommission.percentage(poolPercentages[i]);
            _dexeToken.safeTransfer(
                commissionReceivers[i],
                receivedCommissions[i].convertFrom18(dexeDecimals)
            );
        }

        uint256 insurance = uint256(ICoreProperties.CommissionTypes.INSURANCE);

        IInsurance(commissionReceivers[insurance]).receiveDexeFromPools(
            receivedCommissions[insurance]
        );
    }

    function _distributeCommission(
        uint256 baseToDistribute,
        uint256 lpToDistribute,
        uint256 minDexeCommissionOut
    ) internal {
        require(baseToDistribute > 0, "TP: no commission available");

        (
            uint256 dexePercentage,
            uint256[] memory poolPercentages,
            address[3] memory commissionReceivers
        ) = coreProperties.getDEXECommissionPercentages();

        (uint256 dexeLPCommission, uint256 dexeBaseCommission) = TraderPoolCommission
            .calculateDexeCommission(baseToDistribute, lpToDistribute, dexePercentage);
        uint256 dexeCommission = priceFeed.normalizedExchangeFromExact(
            poolParameters.baseToken,
            address(_dexeToken),
            dexeBaseCommission,
            new address[](0),
            minDexeCommissionOut
        );

        _mint(poolParameters.trader, lpToDistribute - dexeLPCommission);
        _sendDexeCommission(dexeCommission, poolPercentages, commissionReceivers);
    }

    function getReinvestCommissions(uint256 offset, uint256 limit)
        external
        view
        override
        returns (Commissions memory commissions)
    {
        return
            poolParameters.getReinvestCommissions(
                _investors,
                investorsInfo,
                _openPositions.length(),
                offset,
                limit
            );
    }

    function reinvestCommission(
        uint256 offset,
        uint256 limit,
        uint256 minDexeCommissionOut
    ) external virtual override onlyTraderAdmin {
        require(_openPositions.length() == 0, "TP: can't reinvest with opened positions");

        uint256 to = (offset + limit).min(_investors.length()).max(offset);
        uint256 totalSupply = totalSupply();

        uint256 nextCommissionEpoch = poolParameters.nextCommissionEpoch();
        uint256 allBaseCommission;
        uint256 allLPCommission;

        for (uint256 i = offset; i < to; i++) {
            address investor = _investors.at(i);

            if (nextCommissionEpoch > investorsInfo[investor].commissionUnlockEpoch) {
                (
                    uint256 investorBaseAmount,
                    uint256 baseCommission,
                    uint256 lpCommission
                ) = poolParameters.calculateCommissionOnReinvest(
                        investorsInfo[investor],
                        investor,
                        totalSupply
                    );

                investorsInfo[investor].commissionUnlockEpoch = nextCommissionEpoch;

                if (lpCommission > 0) {
                    investorsInfo[investor].investedBase = investorBaseAmount - baseCommission;

                    _burn(investor, lpCommission);

                    allBaseCommission += baseCommission;
                    allLPCommission += lpCommission;
                }
            }
        }

        _distributeCommission(allBaseCommission, allLPCommission, minDexeCommissionOut);
    }

    function _divestPositions(uint256 amountLP, uint256[] calldata minPositionsOut)
        internal
        returns (uint256 investorBaseAmount)
    {
        require(
            amountLP <= balanceOf(_msgSender()) - _investsInBlocks[_msgSender()][block.number],
            "TP: can't divest that amount"
        );

        address baseToken = poolParameters.baseToken;
        IPriceFeed _priceFeed = priceFeed;

        uint256 totalSupply = totalSupply();
        uint256 length = _openPositions.length();
        investorBaseAmount = baseToken.getNormalizedBalance().ratio(amountLP, totalSupply);

        for (uint256 i = 0; i < length; i++) {
            address positionToken = _openPositions.at(i);
            uint256 positionBalance = positionToken.getNormalizedBalance();

            investorBaseAmount += _priceFeed.normalizedExchangeFromExact(
                positionToken,
                baseToken,
                positionBalance.ratio(amountLP, totalSupply),
                new address[](0),
                minPositionsOut[i]
            );
        }
    }

    function _divestInvestor(
        uint256 amountLP,
        uint256[] calldata minPositionsOut,
        uint256 minDexeCommissionOut
    ) internal {
        uint256 investorBaseAmount = _divestPositions(amountLP, minPositionsOut);

        (uint256 baseCommission, uint256 lpCommission) = poolParameters
            .calculateCommissionOnDivest(
                investorsInfo[_msgSender()],
                _msgSender(),
                investorBaseAmount,
                amountLP
            );

        _updateFrom(_msgSender(), amountLP);
        _burn(_msgSender(), amountLP);

        IERC20(poolParameters.baseToken).safeTransfer(
            _msgSender(),
            (investorBaseAmount - baseCommission).convertFrom18(poolParameters.baseTokenDecimals)
        );

        if (baseCommission > 0) {
            _distributeCommission(baseCommission, lpCommission, minDexeCommissionOut);
        }
    }

    function _divestTrader(uint256 amountLP) internal {
        require(
            amountLP <= balanceOf(_msgSender()) - _investsInBlocks[_msgSender()][block.number],
            "TP: can't divest that amount"
        );

        IERC20 baseToken = IERC20(poolParameters.baseToken);
        uint256 traderBaseAmount = baseToken.balanceOf(address(this)).ratio(
            amountLP,
            totalSupply()
        );

        _burn(_msgSender(), amountLP);
        baseToken.safeTransfer(_msgSender(), traderBaseAmount);
    }

    function getDivestAmountsAndCommissions(address user, uint256 amountLP)
        external
        view
        override
        returns (Receptions memory receptions, Commissions memory commissions)
    {
        return
            poolParameters.getDivestAmountsAndCommissions(
                _openPositions,
                investorsInfo[user],
                user,
                amountLP
            );
    }

    function divest(
        uint256 amountLP,
        uint256[] calldata minPositionsOut,
        uint256 minDexeCommissionOut
    ) public virtual override {
        require(!isTrader(_msgSender()) || _openPositions.length() == 0, "TP: can't divest");

        if (isTrader(_msgSender())) {
            _divestTrader(amountLP);
        } else {
            _divestInvestor(amountLP, minPositionsOut, minDexeCommissionOut);
        }
    }

    function _exchange(
        address from,
        address to,
        uint256 amount,
        uint256 amountBound,
        address[] calldata optionalPath,
        bool fromExact
    ) internal {
        require(from != to, "TP: ambiguous exchange");
        require(
            from == poolParameters.baseToken || _openPositions.contains(from),
            "TP: invalid exchange address"
        );

        _checkPriceFeedAllowance(from);
        _checkPriceFeedAllowance(to);

        if (from == poolParameters.baseToken || to != poolParameters.baseToken) {
            _openPositions.add(to);
        }

        if (fromExact) {
            priceFeed.normalizedExchangeFromExact(from, to, amount, optionalPath, amountBound);
        } else {
            priceFeed.normalizedExchangeToExact(from, to, amount, optionalPath, amountBound);
        }

        if (ERC20(from).balanceOf(address(this)) == 0) {
            _openPositions.remove(from);
        }
    }

    function _getExchangeAmount(
        address from,
        address to,
        uint256 amount,
        address[] calldata optionalPath,
        bool fromExact
    ) internal view returns (uint256) {
        return
            poolParameters.getExchangeAmount(
                _openPositions,
                from,
                to,
                amount,
                optionalPath,
                fromExact
            );
    }

    function getExchangeFromExactAmount(
        address from,
        address to,
        uint256 amountIn,
        address[] calldata optionalPath
    ) external view override returns (uint256 minAmountOut) {
        return _getExchangeAmount(from, to, amountIn, optionalPath, true);
    }

    function exchangeFromExact(
        address from,
        address to,
        uint256 amountIn,
        uint256 minAmountOut,
        address[] calldata optionalPath
    ) public virtual override onlyTraderAdmin {
        require(amountIn <= from.getNormalizedBalance(), "TP: invalid exchange amount");

        _exchange(from, to, amountIn, minAmountOut, optionalPath, true);
    }

    function getExchangeToExactAmount(
        address from,
        address to,
        uint256 amountOut,
        address[] calldata optionalPath
    ) external view override returns (uint256 maxAmountIn) {
        return _getExchangeAmount(from, to, amountOut, optionalPath, false);
    }

    function exchangeToExact(
        address from,
        address to,
        uint256 amountOut,
        uint256 maxAmountIn,
        address[] calldata optionalPath
    ) public virtual override onlyTraderAdmin {
        require(maxAmountIn <= from.getNormalizedBalance(), "TP: invalid exchange amount");

        _exchange(from, to, amountOut, maxAmountIn, optionalPath, false);
    }

    function _checkPriceFeedAllowance(address token) internal {
        if (IERC20(token).allowance(address(this), address(priceFeed)) == 0) {
            IERC20(token).safeApprove(address(priceFeed), MAX_UINT);
        }
    }

    function _updateFromData(address investor, uint256 lpAmount)
        internal
        returns (uint256 baseTransfer)
    {
        baseTransfer = investorsInfo[investor].investedBase.ratio(lpAmount, balanceOf(investor));
        investorsInfo[investor].investedBase -= baseTransfer;
    }

    function _checkRemoveInvestor(address investor, uint256 lpAmount) internal {
        if (lpAmount == balanceOf(investor)) {
            _investors.remove(investor);
            investorsInfo[investor].commissionUnlockEpoch = 0;
        }
    }

    function _checkNewInvestor(address investor) internal {
        require(
            !poolParameters.privatePool || isTraderAdmin(investor) || _isPrivateInvestor(investor),
            "TP: private pool"
        );

        if (!_investors.contains(investor)) {
            _investors.add(investor);
            investorsInfo[investor].commissionUnlockEpoch = poolParameters.nextCommissionEpoch();

            require(
                _investors.length() <= coreProperties.getMaximumPoolInvestors(),
                "TP: max investors"
            );
        }
    }

    function _updateFrom(address investor, uint256 lpAmount)
        internal
        returns (uint256 baseTransfer)
    {
        _checkRemoveInvestor(investor, lpAmount);
        return _updateFromData(investor, lpAmount);
    }

    function _updateTo(address investor, uint256 baseAmount) internal {
        _checkNewInvestor(investor);
        investorsInfo[investor].investedBase += baseAmount;
    }

    /// @notice if trader transfers tokens to an investor, we will count them as "earned" and add to the commission calculation
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        require(amount > 0, "TP: 0 transfer");

        if (from != address(0) && to != address(0)) {
            uint256 baseTransfer; // intended to be zero if sender is a trader

            if (!isTrader(from)) {
                baseTransfer = _updateFrom(from, amount);
            }

            if (!isTrader(to)) {
                _updateTo(to, baseTransfer);
            }
        }
    }
}
