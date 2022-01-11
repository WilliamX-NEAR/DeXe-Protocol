// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../core/IPriceFeed.sol";
import "../core/ICoreProperties.sol";

/**
 * The TraderPool contract is a central business logic contract the DEXE platform is built around. The TraderPool represents
 * a collective pool where investors share its funds and the ownership. The share is represented with the LP tokens and the
 * income is made through the trader's activity. The pool itself is tidely integrated with the UniswapV2 protocol and the trader
 * is allowed to trade with the tokens in this pool. Several safety mechanisms are implemented here: Active Portfolio, Trader Leverage,
 * Proposals, Commissions horizon and simplified onchain PathFinder that protect the user funds
 */
interface ITraderPool {
    /// @notice The struct that holds the parameters of this pool
    /// @param descriptionURL the IPFS URL of the description
    /// @param trader the address of trader of this pool
    /// @param privatePool the publicity of the pool. Of the pool is private, only private investors are allowed to invest into it
    /// @param totalLPEmission the total* number of pool's LP tokens. The investors are disallowed to invest more that this number
    /// @param baseToken the address of pool's base token
    /// @param baseTokenDecimals are the decimals of base token (just the gas savings)
    /// @param minimalInvestment is the minimal number of base tokens the investor is allowed to invest (in 18 decimals)
    /// @param commissionPeriod represents the duration of the commission period
    /// @param commissionPercentage trader's commission percentage (DEXE takes commission from this commission)
    struct PoolParameters {
        string descriptionURL;
        address trader;
        bool privatePool;
        uint256 totalLPEmission; // zero means unlimited
        address baseToken;
        uint256 baseTokenDecimals;
        uint256 minimalInvestment; // zero means any value
        ICoreProperties.CommissionPeriod commissionPeriod;
        uint256 commissionPercentage;
    }

    /// @notice The struct that stores basic investor's info
    /// @param investedBase the amount of base tokens the investor invested into the pool (normalized)
    /// @param commissionUnlockEpoch the commission epoch number the trader will be able to take commission from this investor
    struct InvestorInfo {
        uint256 investedBase;
        uint256 commissionUnlockEpoch;
    }

    /// @notice The struct that is returned from the TraderPoolView contract to see the taken commissions
    /// @param traderBaseCommission the total trader's commission in base tokens (normalized)
    /// @param dexeBaseCommission the total platform's commission in base tokens (normalized)
    /// @param dexeDexeCommission the total platform's commission in DEXE tokens (normalized)
    struct Commissions {
        uint256 traderBaseCommission;
        uint256 dexeBaseCommission;
        uint256 dexeDexeCommission;
    }

    /// @notice The struct that is returned from the TraderPoolView contract to see the received amounts
    /// @param baseAmount total received base amount
    /// @param positions the addresses of positions tokens from which the "receivedAmounts" are calculated
    /// @param givenAmounts the amounts (either in base tokens or in position tokens) given
    /// @param receivedAmounts the amounts (either in base tokens or in position tokens) received
    struct Receptions {
        uint256 baseAmount;
        address[] positions;
        uint256[] givenAmounts;
        uint256[] receivedAmounts; // should be used as minAmountOut
    }

    /// @notice The struct that is returned from the TraderPoolView contract and stores information about the trader leverage
    /// @param totalPoolUSD the total USD value of the pool
    /// @param traderLeverageUSDTokens the maximal amount of USD that the trader is allowed to own
    /// @param freeLeverageUSD the amount of USD that could be invested into the pool
    /// @param freeLeverageBase the amount of base tokens that could be invested into the pool (basically converted freeLeverageUSD)
    struct LeverageInfo {
        uint256 totalPoolUSD;
        uint256 traderLeverageUSDTokens;
        uint256 freeLeverageUSD;
        uint256 freeLeverageBase;
    }

    /// @notice The struct that is returned from the TraderPoolView contract and stores information about the investor
    /// @param poolLPBalance the LP token balance of this used excluding proposals balance. The same as calling .balanceOf() function
    /// @param investedBase the amount of base tokens invested into the pool (after commission calculation this might increase)
    /// @param poolUSDShare the amount of USD that represent the user's pool share
    /// @param poolUSDShare the equivalent amount of base tokens that represent the user's pool share
    struct UserInfo {
        uint256 poolLPBalance;
        uint256 investedBase;
        uint256 poolUSDShare;
        uint256 poolBaseShare;
    }

    /// @notice The structure that is returned from the TraderPoolView contract and stores static information about the pool
    /// @param ticker the ERC20 symbol of this pool
    /// @param name the ERC20 name of this pool
    /// @param parameters the active pool parametrs (that are set in the constructor)
    /// @param openPositions the array of open positions addresses
    /// @param baseAndPositionBalances the array of balances. [0] is the balance of base tokens (array is normalized)
    /// @param totalPoolUSD is the current USD TVL in this pool
    /// @param lpEmission is the current number of LP tokens
    struct PoolInfo {
        string ticker;
        string name;
        PoolParameters parameters;
        address[] openPositions;
        uint256[] baseAndPositionBalances;
        uint256 totalInvestors;
        uint256 totalPoolUSD;
        uint256 totalPoolBase;
        uint256 lpEmission;
    }

    /// @notice The function that returns a PriceFeed contract
    /// @return the price feed used
    function priceFeed() external view returns (IPriceFeed);

    /// @notice The function that returns a CoreProperties contract
    /// @return the core properties contract
    function coreProperties() external view returns (ICoreProperties);

    /// @notice The function that checks whther the specified address is a private investor
    /// @param who the address to check
    /// @return true if the pool is private and who is a private investor, false otherwise
    function isPrivateInvestor(address who) external view returns (bool);

    /// @notice The function that checks whether the specified address is a trader admin
    /// @param who the address to check
    /// @return true if who is an admin, false otherwise
    function isTraderAdmin(address who) external view returns (bool);

    /// @notice The function that checks whether the specified address is a trader
    /// @param who the address to check
    /// @return true if who is a trader, false otherwise
    function isTrader(address who) external view returns (bool);

    /// @notice The function to modify trader admins. Trader admins are eligible for executing swaps
    /// @param admins the array of addresses to grant or revoke an admin rights
    /// @param add if true the admins will be added, if fasle the admins will be removed
    function modifyAdmins(address[] calldata admins, bool add) external;

    /// @notice The function to modify private investors
    /// @param privateInvestors the address to be added/removed from private investors list
    /// @param add if true the investors will be added, if false the investors will be removed
    function modifyPrivateInvestors(address[] calldata privateInvestors, bool add) external;

    /// @notice The function to change certain parameters of the pool
    /// @param descriptionURL the IPFS URL to new description
    /// @param privatePool the new access for this pool
    /// @param totalLPEmission the new LP emission for this pool
    /// @param minimalInvestment the new minimal investment bound
    function changePoolParameters(
        string calldata descriptionURL,
        bool privatePool,
        uint256 totalLPEmission,
        uint256 minimalInvestment
    ) external;

    /// @notice The function to get the total number of opened positions right now
    /// @return the number of opened positions
    function totalOpenPositions() external view returns (uint256);

    /// @notice The function to get the total number of investors
    /// @return the total number of investors
    function totalInvestors() external view returns (uint256);

    /// @notice The function to get an address of a proposal pool used by this contract
    /// @return the address of the proposal pool
    function proposalPoolAddress() external view returns (address);

    /// @notice The function that returns the actual LP emmission (the totalSupply() might be less)
    /// @return the actual LP tokens emission
    function totalEmission() external view returns (uint256);

    /// @notice The function that returns the information about the investors
    /// @param offset the starting index of the investors array
    /// @param limit the length of the observed array
    /// @return usersInfo the information about the investors
    function getUsersInfo(uint256 offset, uint256 limit)
        external
        view
        returns (UserInfo[] memory usersInfo);

    /// @notice The funciton to get the static pool information
    /// @return poolInfo the static info of the pool
    function getPoolInfo() external view returns (PoolInfo memory poolInfo);

    /// @notice The function to get the trader leverage information
    /// @return leverageInfo the trader leverage information
    function getLeverageInfo() external view returns (LeverageInfo memory leverageInfo);

    /// @notice The function to get the amounts of positions tokens that will be given to the investor on the investment
    /// @param amountInBaseToInvest normalized amount of base tokens to be invested
    /// @return receptions the information about the tokens received
    function getInvestTokens(uint256 amountInBaseToInvest)
        external
        view
        returns (Receptions memory receptions);

    /// @notice The function to invest into the pool. The "getInvestTokens" function has to be called to receive minPositionsOut amounts
    /// @param amountInBaseToInvest the amount of base tokens to be invested (normalized)
    /// @param minPositionsOut the minimal amounts of position tokens to be received
    function invest(uint256 amountInBaseToInvest, uint256[] calldata minPositionsOut) external;

    /// @notice The function to get the received commissions from the users when the "reinvestCommission" function is called
    /// @param offset the starting index of the investors array
    /// @param limit the number of investors to calculate the commission from
    /// @return commissions the received commissions info
    function getReinvestCommissions(uint256 offset, uint256 limit)
        external
        view
        returns (Commissions memory commissions);

    /// @notice The function that takes the commission from the users' income. This function should be called once per the
    /// commission period. Use "getReinvestCommissions()" function to get minDexeCommissionOut parameter
    /// @param offset the starting index of the users array
    /// @param limit the number of users to take the commission from
    /// @param minDexeCommissionOut the minimal amount of DEXE tokens the platform will receive
    function reinvestCommission(
        uint256 offset,
        uint256 limit,
        uint256 minDexeCommissionOut
    ) external;

    /// @notice The function to get the commissions and received tokens when the "divest" function is called
    /// @param user the address of the user who is going to divest
    /// @param amountLP the amount of LP tokens the users is going to divest
    /// @return receptions the tokens that the user will receive
    /// @return commissions the commissions the user will have to pay
    function getDivestAmountsAndCommissions(address user, uint256 amountLP)
        external
        view
        returns (Receptions memory receptions, Commissions memory commissions);

    /// @notice The function to divest from the pool. The "getDivestAmountsAndCommissions()" function should be called
    /// to receive minPositionsOut and minDexeCommissionOut parameters
    /// @param amountLP the amount of LP tokens to divest
    /// @param minPositionsOut the amount of positions tokens to be converted into the base tokens and given to the user
    /// @param minDexeCommissionOut the DEXE commission in DEXE tokens
    function divest(
        uint256 amountLP,
        uint256[] calldata minPositionsOut,
        uint256 minDexeCommissionOut
    ) external;

    /// @notice The function to get the amount of to tokens received after the swap
    /// @param from the token to exchange from
    /// @param to the token to exchange to
    /// @param amountIn the amount of from tokens to be exchanged
    /// @param optionalPath optional path between from and to tokens used by the pathfinder
    /// @return minAmountOut the amount of to tokens received after the swap
    function getExchangeFromExactAmount(
        address from,
        address to,
        uint256 amountIn,
        address[] calldata optionalPath
    ) external view returns (uint256 minAmountOut);

    /// @notice The function to exchange exact amount of from tokens to the to tokens (aka swapExactTokensForTokens)
    /// @param from the tokens to exchange from
    /// @param to the token to exchange to
    /// @param amountIn the amount of from tokens to exchange (normalized)
    /// @param minAmountOut the minimal amount of to tokens received after the swap
    /// @param optionalPath the optional path between from and to tokens used by the pathfinder
    function exchangeFromExact(
        address from,
        address to,
        uint256 amountIn,
        uint256 minAmountOut,
        address[] calldata optionalPath
    ) external;

    /// @notice The function to get the amount of from tokens required for the swap
    /// @param from the token to exchange from
    /// @param to the token to exchange to
    /// @param amountOut the amount of to tokens to be received
    /// @param optionalPath optional path between from and to tokens used by the pathfinder
    /// @return maxAmountIn the amount of from tokens required for the swap
    function getExchangeToExactAmount(
        address from,
        address to,
        uint256 amountOut,
        address[] calldata optionalPath
    ) external view returns (uint256 maxAmountIn);

    /// @notice The function to exchange from tokens to the exact amount of to tokens (aka swapTokensForExactTokens)
    /// @param from the tokens to exchange from
    /// @param to the token to exchange to
    /// @param amountOut the amount of to tokens received after the swap (normalized)
    /// @param maxAmountIn the maximal amount of from tokens needed for the swap
    /// @param optionalPath the optional path between from and to tokens used by the pathfinder
    function exchangeToExact(
        address from,
        address to,
        uint256 amountOut,
        uint256 maxAmountIn,
        address[] calldata optionalPath
    ) external;
}
