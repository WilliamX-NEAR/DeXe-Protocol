// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "../../trader/TraderPool.sol";

contract TraderPoolMock is TraderPool {
    using EnumerableSet for EnumerableSet.AddressSet;
    using TraderPoolLeverage for PoolParameters;

    function getMaxTraderLeverage() public view returns (uint256 maxTraderLeverage) {
        (, maxTraderLeverage) = poolParameters.getMaxTraderLeverage(_openPositions);
    }

    function proposalPoolAddress() external pure override returns (address) {
        return address(0);
    }

    function totalEmission() public view override returns (uint256) {
        return totalSupply();
    }

    function openPositions() external view returns (address[] memory) {
        return _openPositions.values();
    }
}
