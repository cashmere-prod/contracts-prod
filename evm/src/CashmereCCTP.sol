// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ITokenMessenger} from "./circle/ITokenMessenger.sol";
import {ITokenMessengerV2} from "./circle/ITokenMessengerV2.sol";

contract CashmereCCTP is AccessControl {
    error FeeExceedsAmount();
    error TransferFailed();
    error NativeTransferFailed();
    error InvalidSignature();
    error DeadlineExpired();
    error NativeAmountTooLow();

    error GasDropLimitExceeded();
    error WithdrawCooldownNotPassed();
    error WithdrawLimitExceeded();

    error ReentrancyError();
    error InvalidSignatureLength();
    error Paused();

    uint256 private constant BP = 10000;
    bytes32 private constant EMPTY_BYTES32 = bytes32(0);

    struct State {
        address signer;
        uint64 maxUSDCGasDrop;
        uint32 nonce;
        uint256 lastFeeWithdrawTimestamp;
        uint16 feeBP;
        bool reentrancyLock;
        bool paused;
    }

    State public state;
    mapping (uint32 => uint256) public maxNativeGasDrop;

    uint32 public immutable localDomain;
    ITokenMessenger public immutable tokenMessenger;
    ITokenMessengerV2 public immutable tokenMessengerV2;
    address public immutable usdc;

    uint256 private constant MAX_FEE_BP = 100; // 1%
    uint256 private constant FEE_WITHDRAW_COOLDOWN = 4 hours;
    uint256 private constant FEE_WITHDRAW_LIMIT = 10000 * 1e6; // 10000 USDC

    event FeeBPUpdated(uint16 feeBP);
    event SignerUpdated(address newSigner);
    event FeeWithdraw(address destination, uint256 amount, uint256 nativeAmount);
    event PausedUpdated(bool paused);

    event MaxUSDCGasDropUpdated(uint64 newLimit);
    event MaxNativeGasDropUpdated(uint32 destinaionDomain, uint256 newLimit);

    event CashmereTransfer(
        uint32 destinationDomain,
        uint256 indexed nonce,
        bytes32 recipient,
        bytes32 solanaOwner,
        address indexed user,
        uint256 amount,
        uint256 gasDropAmount,
        bool isNative
    );

    struct TransferParams {
        uint256 amount;
        uint64 fee;
        uint64 deadline;
        uint64 gasDropAmount;
        uint32 destinationDomain;
        bytes32 recipient;
        bytes32 solanaOwner;
        bool isNative;
        bytes signature;
    }

    struct TransferV2Params {
        uint256 amount;
        uint256 maxFee;
        uint64 fee;
        uint64 deadline;
        uint64 gasDropAmount;
        uint32 destinationDomain;
        uint32 minFinalityThreshold;
        bytes32 recipient;
        bytes32 solanaOwner;
        bool isNative;
        bytes hookData;
        bytes signature;
    }

    struct PermitParams {
        uint256 value;
        uint256 deadline;
        bytes signature;
    }

    constructor(
        address _tokenMessenger,
        address _tokenMessengerV2,
        address _usdc
    ) {
        tokenMessenger = ITokenMessenger(_tokenMessenger);
        tokenMessengerV2 = ITokenMessengerV2(_tokenMessengerV2);
        localDomain = tokenMessenger.localMessageTransmitter().localDomain();
        usdc = _usdc;

        state.maxUSDCGasDrop = 100_000_000; // 100 USDC

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        resetApprove();
    }

    modifier _verifySignature(bytes32 _hash, bytes memory _sig) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        if (_sig.length != 65) {
            revert InvalidSignatureLength();
        }

        assembly {
            /*
            First 32 bytes stores the length of the signature

            add(sig, 32) = pointer of sig + 32
            effectively, skips first 32 bytes of signature

            mload(p) loads next 32 bytes starting at the memory address p into memory
            */

            // first 32 bytes, after the length prefix
            r := mload(add(_sig, 32))
            // second 32 bytes
            s := mload(add(_sig, 64))
            // final byte (first byte of the next 32 bytes)
            v := byte(0, mload(add(_sig, 96)))
        }

        if (ecrecover(_hash, v, r, s) != state.signer) {
            revert InvalidSignature();
        }

        _;
    }

    modifier nonReentrant() {
        if (state.reentrancyLock)
            revert ReentrancyError();
        state.reentrancyLock = true;
        _;
        state.reentrancyLock = false;
    }

    modifier checkPause() {
        if (state.paused)
            revert Paused();
        _;
    }

    function _transferFrom(address from, address to, uint256 amount) private {
        (bool success, ) = usdc.call(
            abi.encodeWithSelector(
                IERC20.transferFrom.selector,
                from,
                to,
                amount
            )
        );

        if (!success) {
            revert TransferFailed();
        }
    }

    function getFee(
        uint256 _amount,
        uint256 _staticFee
    ) public view returns (uint256) {
        return (_amount * state.feeBP) / BP + _staticFee;
    }

    function setFeeBP(uint16 _feeBP) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_feeBP <= MAX_FEE_BP, "fee too high");
        state.feeBP = _feeBP;
        emit FeeBPUpdated(_feeBP);
    }

    function setPaused(bool _paused) external onlyRole(DEFAULT_ADMIN_ROLE) {
        state.paused = _paused;
        emit PausedUpdated(_paused);
    }

    function setSigner(address _signer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        state.signer = _signer;
        emit SignerUpdated(_signer);
    }

    function setMaxUSDCGasDrop(uint64 _newLimit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_newLimit > 0, "invalid");
        state.maxUSDCGasDrop = _newLimit;
        emit MaxUSDCGasDropUpdated(_newLimit);
    }

    function setMaxNativeGasDrop(uint32 _destinationDomain, uint256 _newLimit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_newLimit > 0, "invalid");
        maxNativeGasDrop[_destinationDomain] = _newLimit;
        emit MaxNativeGasDropUpdated(_destinationDomain, _newLimit);
    }

    function withdrawFee(
        uint256 _usdcAmount,
        uint256 _nativeAmount,
        address _destination
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (block.timestamp - state.lastFeeWithdrawTimestamp < FEE_WITHDRAW_COOLDOWN) {
            revert WithdrawCooldownNotPassed();
        }

        if (_usdcAmount > FEE_WITHDRAW_LIMIT) {
            revert WithdrawLimitExceeded();
        }

        IERC20(usdc).transfer(_destination, _usdcAmount);
        (bool success, ) = payable(_destination).call{value: _nativeAmount}("");
        if (!success) {
            revert NativeTransferFailed();
        }
        state.lastFeeWithdrawTimestamp = block.timestamp;
        emit FeeWithdraw(_destination, _usdcAmount, _nativeAmount);
    }

    function resetApprove() public onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20(usdc).approve(address(tokenMessenger), type(uint256).max);
        if (address(tokenMessengerV2) != address(0))
            IERC20(usdc).approve(address(tokenMessengerV2), type(uint256).max);
    }

    function transfer(
        TransferParams memory _params
    )
        payable
        external
        nonReentrant
    {
        _transfer(_params);
    }

    function transferV2(
        TransferV2Params memory _params
    )
        payable
        external
        nonReentrant
    {
        _transferV2(_params);
    }

    function _beforeTransfer(
        uint256 deadline,
        uint256 amount,
        uint32 destinationDomain,
        bool isNative,
        uint256 fee,
        uint256 gasDropAmount
    ) internal checkPause() returns (uint256) {
        if (block.timestamp > deadline)
            revert DeadlineExpired();

        uint256 usdcTransferAmount = amount;
        uint256 usdcFeeAmount = getFee(amount, isNative ? 0 : uint256(fee));
        if (isNative) {
            uint256 maxNativeGasDrop_ = maxNativeGasDrop[destinationDomain];
            if (maxNativeGasDrop_ != 0 && gasDropAmount > maxNativeGasDrop_)
                revert GasDropLimitExceeded();
        } else {
            uint256 maxUSDCGasDrop_ = state.maxUSDCGasDrop;
            if (maxUSDCGasDrop_ != 0 && gasDropAmount > maxUSDCGasDrop_)
                revert GasDropLimitExceeded();
        }

        if (!isNative)
            usdcTransferAmount += gasDropAmount;

        if (amount < usdcFeeAmount)
            revert FeeExceedsAmount();

        _transferFrom(msg.sender, address(this), usdcTransferAmount);
        amount -= usdcFeeAmount;

        if (isNative) {
            uint256 nativeFeeAmount = fee + gasDropAmount;
            if (nativeFeeAmount > msg.value) {
                revert NativeAmountTooLow();
            }
            uint256 change = msg.value - nativeFeeAmount;
            if (change > 0) {
                (bool success, ) = msg.sender.call{value: change}("");
                if (!success)
                    revert NativeTransferFailed();
            }
        }

        return amount;
    }

    function _transfer(
        TransferParams memory _params
    )
        internal
        _verifySignature(
            keccak256(
                abi.encodePacked(
                    localDomain,
                    _params.destinationDomain,
                    _params.fee,
                    _params.deadline,
                    _params.isNative,
                    uint8(1)
                )
            ),
            _params.signature
        )
    {
        uint256 amount = _beforeTransfer(
            _params.deadline,
            _params.amount,
            _params.destinationDomain,
            _params.isNative,
            _params.fee,
            _params.gasDropAmount
        );

        tokenMessenger.depositForBurn(
            amount,
            _params.destinationDomain,
            _params.recipient,
            usdc
        );

        emit CashmereTransfer(
            _params.destinationDomain,
            state.nonce++,
            _params.recipient,
            _params.solanaOwner,
            msg.sender,
            amount,
            _params.gasDropAmount,
            _params.isNative
        );
    }

    function _transferV2(
        TransferV2Params memory _params
    )
        internal
        _verifySignature(
            keccak256(
                abi.encodePacked(
                    localDomain,
                    _params.destinationDomain,
                    _params.fee,
                    _params.deadline,
                    _params.isNative,
                    uint8(2)
                )
            ),
            _params.signature
        )
    {
        uint256 amount = _beforeTransfer(
            _params.deadline,
            _params.amount,
            _params.destinationDomain,
            _params.isNative,
            _params.fee,
            _params.gasDropAmount
        );

        tokenMessengerV2.depositForBurnWithHook(
            amount,
            _params.destinationDomain,
            _params.recipient,
            usdc,
            EMPTY_BYTES32,
            _params.maxFee,
            _params.minFinalityThreshold,
            _params.hookData
        );

        emit CashmereTransfer(
            _params.destinationDomain,
            state.nonce++,
            _params.recipient,
            _params.solanaOwner,
            msg.sender,
            amount,
            _params.gasDropAmount,
            _params.isNative
        );
    }

    // --- Permit variant --------------------------------------------------
    function _handlePermit(PermitParams memory _permitParams) internal {
        IUSDCPermit(usdc).permit(
            msg.sender,
            address(this),
            _permitParams.value,
            _permitParams.deadline,
            _permitParams.signature
        );
    }

    function transferWithPermit(
        TransferParams memory _params,
        PermitParams memory _permitParams
    ) payable external nonReentrant {
        _handlePermit(_permitParams);
        _transfer(_params);
    }

    function transferV2WithPermit(
        TransferV2Params memory _params,
        PermitParams memory _permitParams
    ) payable external nonReentrant {
        _handlePermit(_permitParams);
        _transferV2(_params);
    }
}

interface IUSDCPermit is IERC20Permit {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        bytes memory signature
    ) external;
}
