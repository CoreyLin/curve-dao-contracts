# @version 0.2.4
"""
@title Vesting Escrow Factory
@author Curve Finance
@license MIT
@notice Stores and distributes `ERC20CRV` tokens by deploying `VestingEscrowSimple` contracts
通过部署VestingEscrowSimple合约来存储和分发ERC20CRV令牌
"""

from vyper.interfaces import ERC20

MIN_VESTING_DURATION: constant(uint256) = 86400 * 365 # 一年的秒数


interface VestingEscrowSimple:
    def initialize(
        _admin: address,
        _token: address,
        _recipient: address,
        _amount: uint256,
        _start_time: uint256,
        _end_time: uint256,
        _can_disable: bool
    ) -> bool: nonpayable


event CommitOwnership:
    admin: address

event ApplyOwnership:
    admin: address


admin: public(address)
future_admin: public(address)
target: public(address)

@external
def __init__(_target: address, _admin: address):
    """
    @notice Contract constructor
    @dev Prior to deployment you must deploy one copy of `VestingEscrowSimple` which
         is used as a library for vesting contracts deployed by this factory
    @param _target `VestingEscrowSimple` contract address
    合约构造函数
    在部署factory合约之前，必须部署一个VestingEscrowSimple的副本，该副本被用作该工厂合约后续部署的vesting合约的库
    """
    self.target = _target
    self.admin = _admin


@external
def deploy_vesting_contract(
    _token: address,
    _recipient: address,
    _amount: uint256,
    _can_disable: bool,
    _vesting_duration: uint256,
    _vesting_start: uint256 = block.timestamp
) -> address:
    """
    @notice Deploy a new vesting contract
    @dev Each contract holds tokens which vest for a single account. Tokens
         must be sent to this contract via the regular `ERC20.transfer` method
         prior to calling this method.
    @param _token Address of the ERC20 token being distributed
    @param _recipient Address to vest tokens for
    @param _amount Amount of tokens being vested for `_recipient`
    @param _can_disable Can admin disable recipient's ability to claim tokens?
    @param _vesting_duration Time period over which tokens are released
    @param _vesting_start Epoch time when tokens begin to vest
    部署一个新的vesting合约
    每个合约持有代币，为单个账户（地址）vest，即一个vesting合约对应一个账户。在调用本方法之前，代币必须通过常规的ERC20.transfer方法发送到本合约。
    @param _token 正在分发的ERC20 token地址，即治理代币CRV token
    @param _recipient 为谁vest tokens，即受益者
    @param _amount 为_recipient vest的tokens数量
    @param _can_disable 管理员可以禁用_recipient的claim tokens的能力吗?
    @param _vesting_duration 释放代币的时间段，即时间长度
    @param _vesting_start 代币开始vest的纪元时间
    """
    assert msg.sender == self.admin  # dev: admin only
    # 必须在现在或未来的某个时间点开始vest，不能是过去的时间
    assert _vesting_start >= block.timestamp  # dev: start time too soon
    # vest的时间至少持续一年
    assert _vesting_duration >= MIN_VESTING_DURATION  # dev: duration too short

    # 部署一个VestingEscrowSimple合约
    _contract: address = create_forwarder_to(self.target)
    # factory合约approve VestingEscrowSimple合约转移_amount数量的代币
    assert ERC20(_token).approve(_contract, _amount)  # dev: approve failed
    # 初始化
    VestingEscrowSimple(_contract).initialize(
        self.admin,
        _token,
        _recipient,
        _amount,
        _vesting_start,
        _vesting_start + _vesting_duration,
        _can_disable
    )

    return _contract


@external
def commit_transfer_ownership(addr: address) -> bool:
    """
    @notice Transfer ownership of GaugeController to `addr`
    @param addr Address to have ownership transferred to
    """
    assert msg.sender == self.admin  # dev: admin only
    self.future_admin = addr
    log CommitOwnership(addr)

    return True


@external
def apply_transfer_ownership() -> bool:
    """
    @notice Apply pending ownership transfer
    """
    assert msg.sender == self.admin  # dev: admin only
    _admin: address = self.future_admin
    assert _admin != ZERO_ADDRESS  # dev: admin not set
    self.admin = _admin
    log ApplyOwnership(_admin)

    return True
