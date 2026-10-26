// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IMessageTransmitter} from "./IMessageTransmitter.sol";

interface ITokenMessenger {
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken
    ) external returns (uint64 _nonce);

    function localMessageTransmitter() external view returns (IMessageTransmitter);
}
