// SPDX-License-Identifier: BUSL-1.1

/**
 *  █████╗ ███████╗████████╗ █████╗ ██████╗ ██╗ █████╗
 * ██╔══██╗██╔════╝╚══██╔══╝██╔══██╗██╔══██╗██║██╔══██╗
 * ███████║███████╗   ██║   ███████║██████╔╝██║███████║
 * ██╔══██║╚════██║   ██║   ██╔══██║██╔══██╗██║██╔══██║
 * ██║  ██║███████║   ██║   ██║  ██║██║  ██║██║██║  ██║
 * ╚═╝  ╚═╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═╝
 *
 * Astaria Labs, Inc
 */

pragma solidity =0.8.17;

import {Authority} from "solmate/auth/Auth.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {ITransferProxy} from "core/interfaces/ITransferProxy.sol";
import {SafeCastLib} from "gpl/utils/SafeCastLib.sol";
import {
  Create2ClonesWithImmutableArgs
} from "create2-clones-with-immutable-args/Create2ClonesWithImmutableArgs.sol";

import {CollateralLookup} from "core/libraries/CollateralLookup.sol";

import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {ICollateralToken} from "core/interfaces/ICollateralToken.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";
import {IVaultImplementation} from "core/interfaces/IVaultImplementation.sol";
import {IAstariaVaultBase} from "core/interfaces/IAstariaVaultBase.sol";
import {IStrategyValidator} from "core/interfaces/IStrategyValidator.sol";

import {MerkleProofLib} from "core/utils/MerkleProofLib.sol";
import {Pausable} from "core/utils/Pausable.sol";
import {IERC4626} from "core/interfaces/IERC4626.sol";
import {ERC4626Router} from "gpl/ERC4626Router.sol";
import {IPublicVault} from "core/interfaces/IPublicVault.sol";
import {OrderParameters} from "seaport/lib/ConsiderationStructs.sol";
import {AuthInitializable} from "core/AuthInitializable.sol";
import {Initializable} from "./utils/Initializable.sol";

/**
 * @title AstariaRouter
 * @notice This contract manages the deployment of Vaults and universal Astaria actions.
 */
contract AstariaRouter is
  AuthInitializable,
  Initializable,
  ERC4626Router,
  Pausable,
  IAstariaRouter
{
  using SafeTransferLib for ERC20;
  using SafeCastLib for uint256;
  using CollateralLookup for address;
  using FixedPointMathLib for uint256;

  uint256 private constant ROUTER_SLOT =
    uint256(keccak256("xyz.astaria.AstariaRouter.storage.location")) - 1;

  // cast --to-bytes32 $(cast sig "OutOfBoundError()")
  uint256 private constant OUTOFBOUND_ERROR_SELECTOR =
    0x571e08d100000000000000000000000000000000000000000000000000000000;
  uint256 private constant ONE_WORD = 0x20;

  constructor() {
    _disableInitializers();
  }

  /**
   * @dev Setup transfer authority and set up addresses for deployed CollateralToken, LienToken, TransferProxy contracts, as well as PublicVault and SoloVault implementations to clone.
   * @param _AUTHORITY The authority manager.
   * @param _COLLATERAL_TOKEN The address of the deployed CollateralToken contract.
   * @param _LIEN_TOKEN The address of the deployed LienToken contract.
   * @param _TRANSFER_PROXY The address of the deployed TransferProxy contract.
   * @param _VAULT_IMPL The address of a base implementation of VaultImplementation for cloning.
   * @param _SOLO_IMPL The address of a base implementation of a PrivateVault for cloning.
   */
  function initialize(
    Authority _AUTHORITY,
    ICollateralToken _COLLATERAL_TOKEN,
    ILienToken _LIEN_TOKEN,
    ITransferProxy _TRANSFER_PROXY,
    address _VAULT_IMPL,
    address _SOLO_IMPL,
    address _WITHDRAW_IMPL,
    address _BEACON_PROXY_IMPL,
    address _CLEARING_HOUSE_IMPL
  ) external initializer {
    __initAuth(msg.sender, address(_AUTHORITY));
    RouterStorage storage s = _loadRouterSlot();

    s.COLLATERAL_TOKEN = _COLLATERAL_TOKEN;
    s.LIEN_TOKEN = _LIEN_TOKEN;
    s.TRANSFER_PROXY = _TRANSFER_PROXY;
    s.implementations[uint8(ImplementationType.PrivateVault)] = _SOLO_IMPL;
    s.implementations[uint8(ImplementationType.PublicVault)] = _VAULT_IMPL;
    s.implementations[uint8(ImplementationType.WithdrawProxy)] = _WITHDRAW_IMPL;
    s.implementations[
      uint8(ImplementationType.ClearingHouse)
    ] = _CLEARING_HOUSE_IMPL;
    s.BEACON_PROXY_IMPLEMENTATION = _BEACON_PROXY_IMPL;
    s.auctionWindow = uint32(3 days);

    s.liquidationFeeNumerator = uint32(130);
    s.liquidationFeeDenominator = uint32(1000);
    s.minEpochLength = uint32(7 days);
    s.maxEpochLength = uint32(45 days);
    s.maxInterestRate = ((uint256(1e16) * 200) / (365 days));
    //63419583966; // 200% apy / second
    s.guardian = msg.sender;
  }

  function mint(
    IERC4626 vault,
    address to,
    uint256 shares,
    uint256 maxAmountIn
  )
    public
    payable
    virtual
    override
    validVault(address(vault))
    returns (uint256 amountIn)
  {
    return super.mint(vault, to, shares, maxAmountIn);
  }

  function deposit(
    IERC4626 vault,
    address to,
    uint256 amount,
    uint256 minSharesOut
  )
    public
    payable
    virtual
    override
    validVault(address(vault))
    returns (uint256 sharesOut)
  {
    return super.deposit(vault, to, amount, minSharesOut);
  }

  function withdraw(
    IERC4626 vault,
    address to,
    uint256 amount,
    uint256 maxSharesOut
  )
    public
    payable
    virtual
    override
    validVault(address(vault))
    returns (uint256 sharesOut)
  {
    return super.withdraw(vault, to, amount, maxSharesOut);
  }

  function redeem(
    IERC4626 vault,
    address to,
    uint256 shares,
    uint256 minAmountOut
  )
    public
    payable
    virtual
    override
    validVault(address(vault))
    returns (uint256 amountOut)
  {
    return super.redeem(vault, to, shares, minAmountOut);
  }

  function redeemFutureEpoch(
    IPublicVault vault,
    uint256 shares,
    address receiver,
    uint64 epoch
  ) public virtual validVault(address(vault)) returns (uint256 assets) {
    return vault.redeemFutureEpoch(shares, receiver, msg.sender, epoch);
  }

  modifier validVault(address targetVault) {
    if (!isValidVault(targetVault)) {
      revert InvalidVault(targetVault);
    }
    _;
  }

  function pullToken(
    address token,
    uint256 amount,
    address recipient
  ) public payable override {
    RouterStorage storage s = _loadRouterSlot();
    s.TRANSFER_PROXY.tokenTransferFrom(
      address(token),
      msg.sender,
      recipient,
      amount
    );
  }

  function _loadRouterSlot() internal pure returns (RouterStorage storage rs) {
    uint256 slot = ROUTER_SLOT;
    assembly {
      rs.slot := slot
    }
  }

  function feeTo() public view returns (address) {
    RouterStorage storage s = _loadRouterSlot();
    return s.feeTo;
  }

  function BEACON_PROXY_IMPLEMENTATION() public view returns (address) {
    RouterStorage storage s = _loadRouterSlot();
    return s.BEACON_PROXY_IMPLEMENTATION;
  }

  function LIEN_TOKEN() public view returns (ILienToken) {
    RouterStorage storage s = _loadRouterSlot();
    return s.LIEN_TOKEN;
  }

  function TRANSFER_PROXY() public view returns (ITransferProxy) {
    RouterStorage storage s = _loadRouterSlot();
    return s.TRANSFER_PROXY;
  }

  function COLLATERAL_TOKEN() public view returns (ICollateralToken) {
    RouterStorage storage s = _loadRouterSlot();
    return s.COLLATERAL_TOKEN;
  }

  /**
   * @dev Enables _pause, freezing functions with the whenNotPaused modifier.
   */
  function __emergencyPause() external requiresAuth whenNotPaused {
    _pause();
  }

  /**
   * @dev Disables _pause, un-freezing functions with the whenNotPaused modifier.
   */
  function __emergencyUnpause() external requiresAuth whenPaused {
    _unpause();
  }

  function fileBatch(File[] calldata files) external requiresAuth {
    uint256 i;
    for (; i < files.length; ) {
      _file(files[i]);
      unchecked {
        ++i;
      }
    }
  }

  function file(File calldata incoming) public requiresAuth {
    _file(incoming);
  }

  function _file(File calldata incoming) internal {
    RouterStorage storage s = _loadRouterSlot();
    FileType what = incoming.what;
    bytes memory data = incoming.data;
    if (what == FileType.AuctionWindow) {
      uint256 window = abi.decode(data, (uint256));
      s.auctionWindow = window.safeCastTo32();
    } else if (what == FileType.LiquidationFee) {
      (uint256 numerator, uint256 denominator) = abi.decode(
        data,
        (uint256, uint256)
      );
      if (denominator < numerator) revert InvalidFileData();
      s.liquidationFeeNumerator = numerator.safeCastTo32();
      s.liquidationFeeDenominator = denominator.safeCastTo32();
    } else if (what == FileType.ProtocolFee) {
      (uint256 numerator, uint256 denominator) = abi.decode(
        data,
        (uint256, uint256)
      );
      if (denominator < numerator) revert InvalidFileData();
      s.protocolFeeNumerator = numerator.safeCastTo32();
      s.protocolFeeDenominator = denominator.safeCastTo32();
    } else if (what == FileType.MinEpochLength) {
      s.minEpochLength = abi.decode(data, (uint256)).safeCastTo32();
    } else if (what == FileType.MaxEpochLength) {
      s.maxEpochLength = abi.decode(data, (uint256)).safeCastTo32();
    } else if (what == FileType.MaxInterestRate) {
      s.maxInterestRate = abi.decode(data, (uint256));
    } else if (what == FileType.FeeTo) {
      address addr = abi.decode(data, (address));
      if (addr == address(0)) revert InvalidFileData();
      s.feeTo = addr;
    } else if (what == FileType.StrategyValidator) {
      (uint8 TYPE, address addr) = abi.decode(data, (uint8, address));
      if (addr == address(0)) revert InvalidFileData();
      s.strategyValidators[TYPE] = addr;
    } else {
      revert UnsupportedFile();
    }

    emit FileUpdated(what, data);
  }

  function setNewGuardian(address _guardian) external {
    RouterStorage storage s = _loadRouterSlot();
    require(msg.sender == s.guardian);
    s.newGuardian = _guardian;
  }

  function __renounceGuardian() external {
    RouterStorage storage s = _loadRouterSlot();
    require(msg.sender == s.guardian);
    s.guardian = address(0);
    s.newGuardian = address(0);
  }

  function __acceptGuardian() external {
    RouterStorage storage s = _loadRouterSlot();
    require(msg.sender == s.newGuardian);
    s.guardian = s.newGuardian;
    delete s.newGuardian;
  }

  function fileGuardian(File[] calldata file) external {
    RouterStorage storage s = _loadRouterSlot();
    require(msg.sender == address(s.guardian));

    uint256 i;
    for (; i < file.length; ) {
      FileType what = file[i].what;
      bytes memory data = file[i].data;
      if (what == FileType.Implementation) {
        (uint8 implType, address addr) = abi.decode(data, (uint8, address));
        if (addr == address(0)) revert InvalidFileData();
        s.implementations[implType] = addr;
      } else if (what == FileType.CollateralToken) {
        address addr = abi.decode(data, (address));
        if (addr == address(0)) revert InvalidFileData();
        s.COLLATERAL_TOKEN = ICollateralToken(addr);
      } else if (what == FileType.LienToken) {
        address addr = abi.decode(data, (address));
        if (addr == address(0)) revert InvalidFileData();
        s.LIEN_TOKEN = ILienToken(addr);
      } else if (what == FileType.TransferProxy) {
        address addr = abi.decode(data, (address));
        if (addr == address(0)) revert InvalidFileData();
        s.TRANSFER_PROXY = ITransferProxy(addr);
      } else {
        revert UnsupportedFile();
      }
      emit FileUpdated(what, data);
      unchecked {
        ++i;
      }
    }
  }

  //PUBLIC

  function getImpl(uint8 implType) external view returns (address impl) {
    impl = _loadRouterSlot().implementations[implType];
    if (impl == address(0)) {
      revert("unsupported/impl");
    }
  }

  function getAuctionWindow() public view returns (uint256) {
    RouterStorage storage s = _loadRouterSlot();
    return s.auctionWindow;
  }

  function _sliceUint(
    bytes memory bs,
    uint256 start
  ) internal pure returns (uint256 x) {
    uint256 length = bs.length;

    assembly {
      let end := add(ONE_WORD, start)

      if lt(length, end) {
        mstore(0, OUTOFBOUND_ERROR_SELECTOR)
        revert(0, ONE_WORD)
      }

      x := mload(add(bs, end))
    }
  }

  function validateCommitment(
    IAstariaRouter.Commitment calldata commitment,
    uint256 timeToSecondEpochEnd
  ) public view returns (ILienToken.Lien memory lien) {
    return
      _validateCommitment(_loadRouterSlot(), commitment, timeToSecondEpochEnd);
  }

  function _validateCommitment(
    RouterStorage storage s,
    IAstariaRouter.Commitment calldata commitment,
    uint256 timeToSecondEpochEnd
  ) internal view returns (ILienToken.Lien memory lien) {
    uint8 nlrType = uint8(_sliceUint(commitment.lienRequest.nlrDetails, 0));
    address strategyValidator = s.strategyValidators[nlrType];
    if (strategyValidator == address(0)) {
      revert InvalidStrategy(nlrType);
    }
    (bytes32 leaf, ILienToken.Details memory details) = IStrategyValidator(
      strategyValidator
    ).validateAndParse(
        commitment.lienRequest,
        s.COLLATERAL_TOKEN.ownerOf(
          commitment.tokenContract.computeId(commitment.tokenId)
        ),
        commitment.tokenContract,
        commitment.tokenId
      );

    if (details.rate == uint256(0) || details.rate > s.maxInterestRate) {
      revert InvalidCommitmentState(CommitmentState.INVALID_RATE);
    }

    if (details.maxAmount < commitment.lienRequest.amount) {
      revert InvalidCommitmentState(CommitmentState.INVALID_AMOUNT);
    }

    if (
      !MerkleProofLib.verify(
        commitment.lienRequest.merkle.proof,
        commitment.lienRequest.merkle.root,
        leaf
      )
    ) {
      revert InvalidCommitmentState(CommitmentState.INVALID);
    }

    if (timeToSecondEpochEnd > 0 && details.duration > timeToSecondEpochEnd) {
      details.duration = timeToSecondEpochEnd;
    }

    lien = ILienToken.Lien({
      collateralType: nlrType,
      details: details,
      strategyRoot: commitment.lienRequest.merkle.root,
      collateralId: commitment.tokenContract.computeId(commitment.tokenId),
      vault: commitment.lienRequest.strategy.vault,
      token: IAstariaVaultBase(commitment.lienRequest.strategy.vault).asset()
    });
  }

  function commitToLiens(
    IAstariaRouter.Commitment[] memory commitments
  )
    public
    whenNotPaused
    returns (uint256[] memory lienIds, ILienToken.Stack[] memory stack)
  {
    RouterStorage storage s = _loadRouterSlot();

    uint256 totalBorrowed;
    lienIds = new uint256[](commitments.length);
    _transferAndDepositAssetIfAble(
      s,
      commitments[0].tokenContract,
      commitments[0].tokenId
    );

    uint256 i;
    for (; i < commitments.length; ) {
      if (i != 0) {
        commitments[i].lienRequest.stack = stack;
      }
      (lienIds[i], stack) = _executeCommitment(s, commitments[i]);
      totalBorrowed += stack[stack.length - 1].point.amount;
      unchecked {
        ++i;
      }
    }

    ERC20(IAstariaVaultBase(commitments[0].lienRequest.strategy.vault).asset())
      .safeTransfer(msg.sender, totalBorrowed);
  }

  function newVault(
    address delegate,
    address underlying
  ) external whenNotPaused returns (address) {
    address[] memory allowList = new address[](1);
    allowList[0] = msg.sender;
    RouterStorage storage s = _loadRouterSlot();

    return
      _newVault(
        s,
        underlying,
        uint256(0),
        delegate,
        uint256(0),
        true,
        allowList,
        uint256(0)
      );
  }

  function newPublicVault(
    uint256 epochLength,
    address delegate,
    address underlying,
    uint256 vaultFee,
    bool allowListEnabled,
    address[] calldata allowList,
    uint256 depositCap
  ) public whenNotPaused returns (address) {
    RouterStorage storage s = _loadRouterSlot();
    if (s.minEpochLength > epochLength) {
      revert IPublicVault.InvalidState(
        IPublicVault.InvalidStates.EPOCH_TOO_LOW
      );
    }
    if (s.maxEpochLength < epochLength) {
      revert IPublicVault.InvalidState(
        IPublicVault.InvalidStates.EPOCH_TOO_HIGH
      );
    }
    return
      _newVault(
        s,
        underlying,
        epochLength,
        delegate,
        vaultFee,
        allowListEnabled,
        allowList,
        depositCap
      );
  }

  function requestLienPosition(
    IAstariaRouter.Commitment calldata params,
    address receiver
  )
    external
    whenNotPaused
    validVault(msg.sender)
    returns (uint256, ILienToken.Stack[] memory, uint256)
  {
    RouterStorage storage s = _loadRouterSlot();

    return
      s.LIEN_TOKEN.createLien(
        ILienToken.LienActionEncumber({
          lien: _validateCommitment({
            s: s,
            commitment: params,
            timeToSecondEpochEnd: IPublicVault(msg.sender).supportsInterface(
              type(IPublicVault).interfaceId
            )
              ? IPublicVault(msg.sender).timeToSecondEpochEnd()
              : 0
          }),
          amount: params.lienRequest.amount,
          stack: params.lienRequest.stack,
          receiver: receiver
        })
      );
  }

  function canLiquidate(
    ILienToken.Stack memory stack
  ) public view returns (bool) {
    RouterStorage storage s = _loadRouterSlot();
    return (stack.point.end <= block.timestamp);
  }

  function liquidate(
    ILienToken.Stack[] memory stack,
    uint8 position
  ) public whenNotPaused returns (OrderParameters memory listedOrder) {
    if (!canLiquidate(stack[position])) {
      revert InvalidLienState(LienState.HEALTHY);
    }

    RouterStorage storage s = _loadRouterSlot();
    uint256 auctionWindowMax = s.auctionWindow;

    s.LIEN_TOKEN.stopLiens(
      stack[position].lien.collateralId,
      auctionWindowMax,
      stack,
      msg.sender
    );
    emit Liquidation(stack[position].lien.collateralId, position, msg.sender);
    listedOrder = s.COLLATERAL_TOKEN.auctionVault(
      ICollateralToken.AuctionVaultParams({
        settlementToken: stack[position].lien.token,
        collateralId: stack[position].lien.collateralId,
        maxDuration: auctionWindowMax,
        startingPrice: stack[0].lien.details.liquidationInitialAsk,
        endingPrice: 1_000 wei
      })
    );
  }

  function getProtocolFee(uint256 amountIn) external view returns (uint256) {
    RouterStorage storage s = _loadRouterSlot();

    return
      amountIn.mulDivDown(s.protocolFeeNumerator, s.protocolFeeDenominator);
  }

  function getLiquidatorFee(uint256 amountIn) external view returns (uint256) {
    RouterStorage storage s = _loadRouterSlot();

    return
      amountIn.mulDivDown(
        s.liquidationFeeNumerator,
        s.liquidationFeeDenominator
      );
  }

  function isValidVault(address vault) public view returns (bool) {
    return _loadRouterSlot().vaults[vault];
  }

  /**
   * @dev Deploys a new Vault.
   * @param epochLength The length of each epoch for a new PublicVault. If 0, deploys a PrivateVault.
   * @param delegate The address of the Vault delegate.
   * @param allowListEnabled Whether or not the Vault has an LP whitelist.
   * @return vaultAddr The address for the new Vault.
   */
  function _newVault(
    RouterStorage storage s,
    address underlying,
    uint256 epochLength,
    address delegate,
    uint256 vaultFee,
    bool allowListEnabled,
    address[] memory allowList,
    uint256 depositCap
  ) internal returns (address vaultAddr) {
    uint8 vaultType;

    if (underlying.code.length == 0) {
      revert InvalidUnderlying(underlying);
    }
    if (epochLength > uint256(0)) {
      vaultType = uint8(ImplementationType.PublicVault);
    } else {
      vaultType = uint8(ImplementationType.PrivateVault);
    }

    //immutable data
    vaultAddr = Create2ClonesWithImmutableArgs.clone(
      s.BEACON_PROXY_IMPLEMENTATION,
      abi.encodePacked(
        address(this),
        vaultType,
        msg.sender,
        underlying,
        block.timestamp,
        epochLength,
        vaultFee
      ),
      keccak256(abi.encodePacked(msg.sender, blockhash(block.number - 1)))
    );

    if (s.LIEN_TOKEN.balanceOf(vaultAddr) > 0) {
      revert InvalidVaultState(IAstariaRouter.VaultState.CORRUPTED);
    }
    //mutable data
    IVaultImplementation(vaultAddr).init(
      IVaultImplementation.InitParams({
        delegate: delegate,
        allowListEnabled: allowListEnabled,
        allowList: allowList,
        depositCap: depositCap
      })
    );

    s.vaults[vaultAddr] = true;

    emit NewVault(msg.sender, delegate, vaultAddr, vaultType);

    return vaultAddr;
  }

  function _executeCommitment(
    RouterStorage storage s,
    IAstariaRouter.Commitment memory c
  ) internal returns (uint256, ILienToken.Stack[] memory stack) {
    uint256 collateralId = c.tokenContract.computeId(c.tokenId);

    if (msg.sender != s.COLLATERAL_TOKEN.ownerOf(collateralId)) {
      revert InvalidSenderForCollateral(msg.sender, collateralId);
    }
    if (!s.vaults[c.lienRequest.strategy.vault]) {
      revert InvalidVault(c.lienRequest.strategy.vault);
    }
    //router must be approved for the collateral to take a loan,
    return IVaultImplementation(c.lienRequest.strategy.vault).commitToLien(c);
  }

  function _transferAndDepositAssetIfAble(
    RouterStorage storage s,
    address tokenContract,
    uint256 tokenId
  ) internal {
    ERC721 token = ERC721(tokenContract);
    if (token.ownerOf(tokenId) == msg.sender) {
      token.safeTransferFrom(
        msg.sender,
        address(s.COLLATERAL_TOKEN),
        tokenId,
        ""
      );
    }
  }
}
