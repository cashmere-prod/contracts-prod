// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IMessageTransmitter {
    function receiveMessage(
        bytes memory message,
        bytes memory attestation
    ) external;

    function localDomain() external view returns (uint32);
}
