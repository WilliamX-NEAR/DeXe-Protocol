// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./ITraderPoolProposal.sol";

interface ITraderPoolInvestProposal is ITraderPoolProposal {
    struct ProposalLimits {
        uint256 timestampLimit;
        uint256 investLPLimit;
    }

    struct ProposalInfo {
        ProposalLimits proposalLimits;
        uint256 cumulativeSum; // with PRECISION
        uint256 investedLP;
        uint256 investedBase;
        uint256 newInvestedBase;
    }

    struct RewardInfo {
        uint256 rewardStored;
        uint256 cumulativeSumStored; // with PRECISION
    }

    function __TraderPoolInvestProposal_init(ParentTraderPoolInfo calldata parentTraderPoolInfo)
        external;

    function changeProposalRestrictions(uint256 proposalId, ProposalLimits calldata proposalLimits)
        external;

    function createProposal(
        ProposalLimits calldata proposalLimits,
        uint256 lpInvestment,
        uint256 baseInvestment
    ) external;

    function investProposal(
        uint256 proposalId,
        address user,
        uint256 lpInvestment,
        uint256 baseInvestment
    ) external;

    function claimProposal(uint256 proposalId, address user) external returns (uint256);

    function claimAllProposals(address user) external returns (uint256);

    function withdraw(uint256 proposalId, uint256 amount) external;

    function convertToDividends(uint256 proposalId) external;

    function supply(
        uint256 proposalId,
        address user,
        uint256 amount
    ) external;
}
