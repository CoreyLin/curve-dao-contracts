# @version 0.2.4
"""
@title Simple Vesting Escrow
@author Curve Finance
@license MIT
@notice Vests `ERC20CRV` tokens for a single address
为单个地址托管ERC20CRV tokens
@dev Intended to be deployed many times via `VotingEscrowFactory`
打算通过“VotingEscrowFactory”部署多次
"""

from vyper.interfaces import ERC20

event Fund:
    recipient: indexed(address)
    amount: uint256

event Claim:
    recipient: indexed(address)
    claimed: uint256

event ToggleDisable:
    recipient: address
    disabled: bool

event CommitOwnership:
    admin: address

event ApplyOwnership:
    admin: address


token: public(address)
start_time: public(uint256)
end_time: public(uint256)
initial_locked: public(HashMap[address, uint256]) # 地址和初始锁定治理代币的数量的映射
total_claimed: public(HashMap[address, uint256])

initial_locked_supply: public(uint256)

can_disable: public(bool)
disabled_at: public(HashMap[address, uint256])

admin: public(address)
future_admin: public(address)

@external
def __init__():
    # ensure that the original contract cannot be initialized
    self.admin = msg.sender


@external
@nonreentrant('lock')
def initialize( # 在本合约被工厂合约部署时调用
    _admin: address,
    _token: address,
    _recipient: address,
    _amount: uint256,
    _start_time: uint256,
    _end_time: uint256,
    _can_disable: bool
) -> bool:
    """
    @notice Initialize the contract.
    @dev This function is seperate from `__init__` because of the factory pattern
         used in `VestingEscrowFactory.deploy_vesting_contract`. It may be called
         once per deployment.
    @param _admin Admin address
    @param _token Address of the ERC20 token being distributed
    @param _recipient Address to vest tokens for
    @param _amount Amount of tokens being vested for `_recipient`
    @param _start_time Epoch time at which token distribution starts
    @param _end_time Time until everything should be vested
    @param _can_disable Can admin disable recipient's ability to claim tokens?

    @notice 初始化合约。
    @dev 这个函数与__init__是分开的，因为VestingEscrowFactory.deploy_vesting_contract中使用了工厂模式。它可以在每次部署时调用一次。
    @param _admin 管理员地址
    @param _token 正在分发的ERC20 token地址，即治理代币CRV token
    @param _recipient 为谁vest tokens，即受益者
    @param _amount 为_recipient vest的tokens数量
    @param _start_time token分发开始的Epoch时间，即vest开始时间
    @param _end_time 直到这个时间一切都应该被vested，即vest截止时间
    @param _can_disable 管理员可以禁用_recipient的claim tokens的能力吗?
    """
    # self.admin只能被初始化一次
    assert self.admin == ZERO_ADDRESS  # dev: can only initialize once

    self.token = _token
    self.admin = _admin
    self.start_time = _start_time
    self.end_time = _end_time
    self.can_disable = _can_disable

    # 治理代币持有人把指定数量的治理代币发送到本合约
    assert ERC20(_token).transferFrom(msg.sender, self, _amount)

    # _recipient的初始锁定的治理代币的数量为_amount
    # 此处是本合约唯一一次更新self.initial_locked的地方，意味着只有在initialize里面才能设置self.initial_locked的值
    self.initial_locked[_recipient] = _amount
    # 初始锁定的治理代币的总量为_amount
    self.initial_locked_supply = _amount
    log Fund(_recipient, _amount)

    return True


@external
def toggle_disable(_recipient: address):
    """
    @notice Disable or re-enable a vested address's ability to claim tokens
    @dev When disabled, the address is only unable to claim tokens which are still
         locked at the time of this call. It is not possible to block the claim
         of tokens which have already vested.
    @param _recipient Address to disable or enable

    @notice 禁用或重新启用已vested地址的claim tokens的能力
    @dev 禁用时，该地址只是不能claim在本次调用时仍被锁定的tokens。不可能阻止claim已经vested的tokens。这句话的言下之意就是lock和vest是两个概念。
    @param __recipient 要禁用或启用的地址
    """
    # 只有admin有这个权力
    assert msg.sender == self.admin  # dev: admin only
    # 本合约必须能够被disable，这是个全局设置
    assert self.can_disable, "Cannot disable"

    # self.disabled_at[_recipient] == 0为true意味着_recipient没有被disable，则需要对其进行disable
    is_disabled: bool = self.disabled_at[_recipient] == 0
    if is_disabled: # 需要disable
        self.disabled_at[_recipient] = block.timestamp
    else: # 需要解除disable
        self.disabled_at[_recipient] = 0

    log ToggleDisable(_recipient, is_disabled)


@external
def disable_can_disable():
    """
    @notice Disable the ability to call `toggle_disable`
    禁用调用toggle_disable的能力
    """
    assert msg.sender == self.admin  # dev: admin only
    self.can_disable = False

@internal
@view
# 获取给定地址已经被vested的代币数量，小于等于初始锁定代币数量，和时间相关
# 第二个参数_time有默认值，如果不传参数，则默认参数是当前时间戳
def _total_vested_of(_recipient: address, _time: uint256 = block.timestamp) -> uint256:
    # token分发开始的Epoch时间，即vest开始时间
    start: uint256 = self.start_time
    # 直到这个时间一切都应该被vested，即vest截止时间
    end: uint256 = self.end_time
    # initial_locked是地址和初始锁定治理代币的数量的映射
    locked: uint256 = self.initial_locked[_recipient]
    if _time < start:
        return 0
    # 举例，如果start是1月1号，end是1月31号，当前时间是1月15号，那么vested的代币数量是locked的代币数量的一半
    # 随着时间的推移，vested的代币数量会越来越多，更接近locked的代币数量，直到vest截止时间，所有锁定的代币都被vested了
    return min(locked * (_time - start) / (end - start), locked)

# 返回已经被vested的代币数量，小于等于初始锁定代币数量
@internal
@view
def _total_vested() -> uint256:
    start: uint256 = self.start_time
    end: uint256 = self.end_time
    locked: uint256 = self.initial_locked_supply
    if block.timestamp < start: # vest都还没开始，没到开始时间，所以，无论lock了多少治理代币，vested的数量是0
        return 0
    # 举例，如果start是1月1号，end是1月31号，当前时间是1月15号，那么vested的代币数量是locked的代币数量的一半
    # 随着时间的推移，vested的代币数量会越来越多，更接近locked的代币数量，直到vest截止时间，所有锁定的代币都被vested了
    return min(locked * (block.timestamp - start) / (end - start), locked)

# 返回已经被vested的代币数量，小于等于初始锁定代币数量
@external
@view
def vestedSupply() -> uint256:
    """
    @notice Get the total number of tokens which have vested, that are held
            by this contract
    获得已vested的代币的总数，由该合约持有
    """
    return self._total_vested()


@external
@view
def lockedSupply() -> uint256:
    """
    @notice Get the total number of tokens which are still locked
            (have not yet vested)
    获得仍被锁定(但尚未vested)的tokens总数
    """
    return self.initial_locked_supply - self._total_vested()


@external
@view
def vestedOf(_recipient: address) -> uint256:
    """
    @notice Get the number of tokens which have vested for a given address
    @param _recipient address to check
    获取给定地址已vested的tokens数量
    """
    return self._total_vested_of(_recipient)


@external
@view
def balanceOf(_recipient: address) -> uint256:
    """
    @notice Get the number of unclaimed, vested tokens for a given address
    @param _recipient address to check
    获取给定地址的还未claim的、已经vested的tokens的数量
    言下之意就是vest之后的下一步就是claim
    """
    return self._total_vested_of(_recipient) - self.total_claimed[_recipient]


@external
@view
def lockedOf(_recipient: address) -> uint256:
    """
    @notice Get the number of locked tokens for a given address
    @param _recipient address to check
    获取给定地址的锁定tokens数量
    """
    return self.initial_locked[_recipient] - self._total_vested_of(_recipient)


@external
@nonreentrant('lock')
def claim(addr: address = msg.sender):
    """
    @notice Claim tokens which have vested
    @param addr Address to claim tokens for
    claim已经vested的tokens。顺序是：先vest，再claim。
    """
    # self.disabled_at[_recipient] == 0为true意味着_recipient没有被disable
    t: uint256 = self.disabled_at[addr]
    # 如果_recipient没有被disable，则每次都取当前时间戳
    if t == 0:
        t = block.timestamp # 如果是第一次claim，则把t设置为当前的时间戳
    # 步骤：
    # 1.获取给定地址已经被vested的代币数量，小于等于初始锁定代币数量，和时间相关
    # 2.用已经vested的代币数量，减去该地址已经claim的代币数量，就是该地址当前还能够claim的代币数量
    # 注意：只有已经vested的代币才能进行claim
    claimable: uint256 = self._total_vested_of(addr, t) - self.total_claimed[addr]
    # 该地址已经claim的代币数量相应增加
    self.total_claimed[addr] += claimable
    # 把相应数量的治理代币从本合约发给用户。这些治理代币是之前用户发给本合约来锁定和vest的。
    assert ERC20(self.token).transfer(addr, claimable)

    log Claim(addr, claimable)


@external
def commit_transfer_ownership(addr: address) -> bool:
    """
    @notice Transfer ownership of GaugeController to `addr`
    @param addr Address to have ownership transferred to
    将GaugeController的所有权转移到addr，只有admin才能操作
    """
    assert msg.sender == self.admin  # dev: admin only
    # 设置未来的admin，注意，现在的admin还是没变，这里只是设置未来的
    self.future_admin = addr
    log CommitOwnership(addr)

    return True


@external
def apply_transfer_ownership() -> bool:
    """
    @notice Apply pending ownership transfer
    正式把未来的admin设置为现在的admin
    """
    assert msg.sender == self.admin  # dev: admin only
    _admin: address = self.future_admin
    assert _admin != ZERO_ADDRESS  # dev: admin not set
    self.admin = _admin
    log ApplyOwnership(_admin)

    return True
