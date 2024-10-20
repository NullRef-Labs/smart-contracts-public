//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.2 <0.9.0;


/**
 * Standard SafeMath, stripped down to just add/sub/mul/div
 */
library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");

        return c;
    }
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return sub(a, b, "SafeMath: subtraction overflow");
    }
    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        uint256 c = a - b;

        return c;
    }
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");

        return c;
    }
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(a, b, "SafeMath: division by zero");
    }
    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        // Solidity only automatically asserts when dividing by 0
        require(b > 0, errorMessage);
        uint256 c = a / b;
        // assert(a == b * c + a % b); // There is no case in which this doesn't hold

        return c;
    }
}

/**
 * ERC20 standard interface.
 */
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
    function name() external view returns (string memory);
    function getOwner() external view returns (address);
    function balanceOf(address _account) external view returns (uint256);
    function transfer(address _recipient, uint256 _amount) external returns (bool);
    function allowance(address _owner, address _spender) external view returns (uint256);
    function approve(address _spender, uint256 _amount) external returns (bool);
    function transferFrom(address _sender, address _recipient, uint256 _amount) external returns (bool);
    event Transfer(address indexed _from, address indexed _to, uint256 _value);
    event Approval(address indexed _owner, address indexed _spender, uint256 _value);
}

/**
 * Allows for contract ownership along with multi-address authorization
 */
abstract contract Auth {
    address internal m_Owner;
    mapping(address => bool) internal m_Admins;
    
    event OwnershipTransferred(address _owner);
    event AdminStatusChanged(address _admin, bool _status);

    constructor(address _owner) {
        m_Owner = _owner;
        setAdminStatus(m_Owner, true);
    }

    /**
     * Function modifier to require caller to be contract deployer
     */
    modifier onlyOwner() {
        require(msg.sender == m_Owner, "!Owner"); 
        _;
    }

    modifier onlyAdmin() {
        require(m_Admins[msg.sender], "!Admin");
        _;
    }

    /**
     * Transfer ownership to new address. Caller must be deployer. Leaves old deployer authorized
     */
    function transferOwnership(address payable _addr) public onlyOwner {
        m_Owner = _addr;
        emit OwnershipTransferred(_addr);
    }

    function setAdminStatus(address _admin, bool _status) public onlyOwner {
        m_Admins[_admin] = _status;
    }
}

interface IDEXFactory {
    function createPair(address _tokenA, address _tokenB) external returns (address _pair);
}

interface IDEXRouter {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

interface IDividendDistributor {
    function setShare(address _shareholder, uint256 _amount) external;
    function deposit() external payable;
    function claimDividend(address _shareholder) external;
}

contract DividendDistributor is IDividendDistributor {
    using SafeMath for uint256;

    address private m_Token;

    struct Share {
        uint256 amount;
        uint256 totalExcluded;
        uint256 totalRealised;
    }

    address[] private m_Shareholders;
    mapping (address => uint256) private m_ShareholderIndexes;
    mapping (address => Share) public m_Shares;

    uint256 public m_TotalShares;
    uint256 public m_TotalDividends;
    uint256 public m_TotalDistributed;
    uint256 public m_DividendsPerShare;
    uint256 private m_DividendsPerShareAccuracyFactor = 10 ** 36;

    modifier onlyToken() {
        require(msg.sender == m_Token); 
        _;
    }

    constructor () {
        m_Token = msg.sender;
    }

    function setShare(address _shareholder, uint256 _amount) external override onlyToken {
        if(m_Shares[_shareholder].amount > 0){
            distributeDividend(_shareholder);
        }

        if(_amount > 0 && m_Shares[_shareholder].amount == 0){
            addShareholder(_shareholder);
        }else if(_amount == 0 && m_Shares[_shareholder].amount > 0){
            removeShareholder(_shareholder);
        }

        m_TotalShares = m_TotalShares.sub(m_Shares[_shareholder].amount).add(_amount);
        m_Shares[_shareholder].amount = _amount;
        m_Shares[_shareholder].totalExcluded = getCumulativeDividends(m_Shares[_shareholder].amount);
    }

    function deposit() external payable override onlyToken {
        uint256 _amount = msg.value;

        m_TotalDividends = m_TotalDividends.add(_amount);
        m_DividendsPerShare = m_DividendsPerShare.add(m_DividendsPerShareAccuracyFactor.mul(_amount).div(m_TotalShares));
    }
    
    function distributeDividend(address _shareholder) internal {
        if(m_Shares[_shareholder].amount == 0){ return; }

        uint256 _amount = getUnpaidEarnings(_shareholder);
        if(_amount > 0){
            m_TotalDistributed = m_TotalDistributed.add(_amount);
            m_Shares[_shareholder].totalRealised = m_Shares[_shareholder].totalRealised.add(_amount);
            m_Shares[_shareholder].totalExcluded = getCumulativeDividends(m_Shares[_shareholder].amount);
            payable(_shareholder).transfer(_amount);
        }
    }
    
    function claimDividend(address _shareholder) external override onlyToken {
        distributeDividend(_shareholder);
    }

    function getUnpaidEarnings(address _shareholder) public view returns (uint256) {
        if(m_Shares[_shareholder].amount == 0) { 
            return 0; 
        }

        uint256 _shareholderTotalDividends = getCumulativeDividends(m_Shares[_shareholder].amount);
        uint256 _shareholderTotalExcluded = m_Shares[_shareholder].totalExcluded;

        if(_shareholderTotalDividends <= _shareholderTotalExcluded) { 
            return 0; 
        }

        return _shareholderTotalDividends.sub(_shareholderTotalExcluded);
    }

    function getCumulativeDividends(uint256 _share) internal view returns (uint256) {
        return _share.mul(m_DividendsPerShare).div(m_DividendsPerShareAccuracyFactor);
    }

    function getShareholderRealizedEarnings(address _shareholder) external view returns (uint256) {
        return m_Shares[_shareholder].totalRealised;
    }

    function getTotalDistributed() external view returns (uint256) {
        return m_TotalDistributed;
    }

    function addShareholder(address _shareholder) internal {
        m_ShareholderIndexes[_shareholder] = m_Shareholders.length;
        m_Shareholders.push(_shareholder);
    }

    function removeShareholder(address _shareholder) internal {
        m_Shareholders[m_ShareholderIndexes[_shareholder]] = m_Shareholders[m_Shareholders.length-1];
        m_ShareholderIndexes[m_Shareholders[m_Shareholders.length-1]] = m_ShareholderIndexes[_shareholder];
        m_Shareholders.pop();
    }
}

contract Trend is IERC20, Auth {
    using SafeMath for uint256;

    address private WETH;
    address private DEAD = 0x000000000000000000000000000000000000dEaD;
    address private ZERO = 0x0000000000000000000000000000000000000000;

    string private constant  m_Name = "TREND";
    string private constant m_Symbol = "TREND";
    uint8 private constant m_Decimals = 9;

    uint256 private m_TotalSupply = 10000000000 * (10 ** m_Decimals);
    uint256 private m_MaxBuyAmount = m_TotalSupply;
    uint256 private m_MaxSellAmount = m_TotalSupply;

    mapping (address => uint256) private m_Balances;
    mapping (address => mapping (address => uint256)) private m_Allowances;

    mapping (address => bool) private m_IsFeeExempt;
    mapping (address => bool) private m_IsTxLimitExempt;
    mapping (address => bool) private m_IsDividendExempt;
    mapping (address => bool) private m_IsBot;
    mapping (address => bool) private m_Pairs;

    uint256 private m_TransferOutLimitPeriod = 30 * 24 * 60 * 60; // 30 days
    uint256 private m_TransferOutLimit = 5000000 * (10 ** m_Decimals); // 5M tokens
    // time left in period for user before m_TransferOutAmount resets
    mapping (address => uint256) private m_TransferOutLimitExpiration;
    // amount transferred out before m_TransferOutLimitExpiration
    mapping (address => uint256) private m_TransferOutAmount;

    uint256 private m_InitialBlockLimit = 1;
    
    uint256 private m_ReflectionFee = 4;
    uint256 private m_TeamFee = 4;
    uint256 private m_TotalFee = 8;
    uint256 private m_FeeDenominator = 100;

    address private m_TeamReceiver;

    IDEXRouter public m_Router;
    address public m_Pair;

    uint256 public m_LaunchedAt;

    DividendDistributor private m_Distributor;

    bool public m_SwapEnabled = true;
    uint256 public m_SwapThreshold = m_TotalSupply / 1000; // 10M
    
    bool private m_InSwap;
    modifier swapping() { 
        m_InSwap = true;
        _; 
        m_InSwap = false; 
    }

    constructor (
        address _owner,
        address _teamWallet
    ) Auth(_owner) {
        m_Router = IDEXRouter(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
            
        WETH = m_Router.WETH();
        
        m_Pair = IDEXFactory(m_Router.factory()).createPair(WETH, address(this));
        m_Pairs[m_Pair] = true;
        
        m_Allowances[address(this)][address(m_Router)] = type(uint256).max;

        m_Distributor = new DividendDistributor();

        m_IsFeeExempt[_owner] = true;
        m_IsFeeExempt[_teamWallet] = true;
        
        m_IsTxLimitExempt[_owner] = true;
        m_IsTxLimitExempt[DEAD] = true;
        m_IsTxLimitExempt[_teamWallet] = true;
        
        m_IsDividendExempt[m_Pair] = true;
        m_IsDividendExempt[address(this)] = true;
        m_IsDividendExempt[DEAD] = true;

        m_TeamReceiver = _teamWallet;

        m_Balances[_owner] = m_TotalSupply;
    
        emit Transfer(address(0), _owner, m_TotalSupply);
    }

    receive() external payable { }

    function totalSupply() external view override returns (uint256) { return m_TotalSupply; }
    function decimals() external pure override returns (uint8) { return m_Decimals; }
    function symbol() external pure override returns (string memory) { return m_Symbol; }
    function name() external pure override returns (string memory) { return m_Name; }
    function getOwner() external view override returns (address) { return m_Owner; }
    function balanceOf(address _account) public view override returns (uint256) { return m_Balances[_account]; }
    function allowance(address _holder, address _spender) external view override returns (uint256) { return m_Allowances[_holder][_spender]; }

    function approve(address _spender, uint256 _amount) public override returns (bool) {
        m_Allowances[msg.sender][_spender] = _amount;
        emit Approval(msg.sender, _spender, _amount);
        return true;
    }

    function approveMax(address _spender) external returns (bool) {
        return approve(_spender, type(uint256).max);
    }

    function transfer(address _recipient, uint256 amount) external override returns (bool) {
        return _transferFrom(msg.sender, _recipient, amount);
    }

    function transferFrom(address _sender, address _recipient, uint256 _amount) external override returns (bool) {
        if(m_Allowances[_sender][msg.sender] != type(uint256).max){
            m_Allowances[_sender][msg.sender] = m_Allowances[_sender][msg.sender].sub(_amount, "Insufficient Allowance");
        }

        return _transferFrom(_sender, _recipient, _amount);
    }

    function _transferFrom(address _sender, address _recipient, uint256 _amount) internal returns (bool) {
        if(m_InSwap) { 
            return _basicTransfer(_sender, _recipient, _amount); 
        }
        
        _checkTxLimit(_sender, _recipient, _amount);
        _checkTransferOutLimit(_sender, _amount);

        if(_shouldEmitFees()) { 
            _emitFees(); 
        }

        if( !_isLaunched() && _isPair(_recipient) ) { 
            require(m_Balances[_sender] > 0); 
            _launch(); 
        }

        m_Balances[_sender] = m_Balances[_sender].sub(_amount, "Insufficient Balance");

        uint256 _amountReceived = _shouldTakeFee(_sender, _recipient) ? _takeFee(_sender, _recipient, _amount) : _amount;
        
        m_Balances[_recipient] = m_Balances[_recipient].add(_amountReceived);

        if(!_isPair(_sender) && !m_IsDividendExempt[_sender]) { 
            try m_Distributor.setShare(_sender, m_Balances[_sender]) {
            } catch {} 
        }
        if(!_isPair(_recipient) && !m_IsDividendExempt[_recipient]) { 
            try m_Distributor.setShare(_recipient, m_Balances[_recipient]) {
            } catch {} 
        }

        emit Transfer(_sender, _recipient, _amountReceived);
        return true;
    }
    
    function _basicTransfer(address _sender, address _recipient, uint256 _amount) internal returns (bool) {
        m_Balances[_sender] = m_Balances[_sender].sub(_amount, "Insufficient Balance");
        m_Balances[_recipient] = m_Balances[_recipient].add(_amount);
        emit Transfer(_sender, _recipient, _amount);
        return true;
    }

    function _checkTxLimit(address _sender, address _recipient, uint256 _amount) internal view {
        _isPair(_sender) ? 
            require(_amount <= m_MaxBuyAmount || m_IsTxLimitExempt[_recipient], "Buy Limit Exceeded") :
            require(_amount <= m_MaxSellAmount || m_IsTxLimitExempt[_sender], "Sell Limit Exceeded");
    }

    function _checkTransferOutLimit(address _sender, uint256 _amount) internal {
        if (_isPair(_sender)) return;

        if (block.timestamp > m_TransferOutLimitExpiration[_sender]) {
            m_TransferOutLimitExpiration[_sender] = block.timestamp + m_TransferOutLimitPeriod;
            m_TransferOutAmount[_sender] = 0;
        }

        m_TransferOutAmount[_sender] += _amount;
        require(m_TransferOutAmount[_sender] <= m_TransferOutLimit, "TRANSFER_OUT_LIMIT_EXCEEDED_FOR_PERIOD");
    }

    function _shouldTakeFee(address _sender, address _recipient) internal view returns (bool) {
        return !(m_IsFeeExempt[_sender] || m_IsFeeExempt[_recipient]);
    }

    function _takeFee(address _sender, address _recipient, uint256 _amount) internal returns (uint256) {
        uint256 _feeAmount;
        bool _bot;
        
        // Add all the fees to the contract. In case of Sell, it will be multiplied fees.
        if (!_isPair(_sender)) {
            _bot = m_IsBot[_sender];
        } else {
            _bot = m_IsBot[_recipient];
        }
        
        // if this is a bot or launch sniper
        if (_bot || m_LaunchedAt + m_InitialBlockLimit >= block.number) {
            _feeAmount = _amount.mul(m_FeeDenominator.sub(1)).div(m_FeeDenominator);
            m_Balances[DEAD] = m_Balances[DEAD].add(_feeAmount);
            emit Transfer(_sender, DEAD, _feeAmount);
        } 
        // normal trade
        else {
            // tax buys, sells, and transfers differently
            _feeAmount = 
                _isPair(_sender) ? _amount.mul(m_TotalFee).div(m_FeeDenominator) : // buy
                _isPair(_recipient) ? _amount.mul(m_TotalFee).div(m_FeeDenominator) : // sell
                0; // transfer
            m_Balances[address(this)] = m_Balances[address(this)].add(_feeAmount);
            emit Transfer(_sender, address(this), _feeAmount);
        }

        return _amount.sub(_feeAmount);
    }

    function _shouldEmitFees() internal view returns (bool) {
        return 
            // # TODO should we do this on transfers? or only sells?
            // if not a buy
            !_isPair(msg.sender) 
            // if not swapping
            && !m_InSwap
            // if swapping enabled
            && m_SwapEnabled
            // if fees accrued meet threshold
            && m_Balances[address(this)] >= m_SwapThreshold;
    }

    function _emitFees() internal swapping {
        uint256 _amountToSwap = m_SwapThreshold;

        address[] memory _path = new address[](2);
        _path[0] = address(this);
        _path[1] = WETH;

        uint256 balanceBefore = address(this).balance;

        m_Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            _amountToSwap,
            0,
            _path,
            address(this),
            block.timestamp
        );
        uint256 _amountETH = address(this).balance.sub(balanceBefore);
        uint256 _amountReflection = _amountETH.mul(m_ReflectionFee).div(m_TotalFee);
        uint256 _amountTeam = _amountETH.sub(_amountReflection);

        try m_Distributor.deposit{value: _amountReflection}() {
        } catch {}
        
        payable(m_TeamReceiver).transfer(_amountTeam);
    }

    function _isLaunched() internal view returns (bool) {
        return m_LaunchedAt != 0;
    }

    function _launch() internal {
        //To know when it was launched
        m_LaunchedAt = block.number;
    }

    function _isPair(address _addr) internal view returns (bool) {
        return m_Pairs[_addr];
    }

    function updatePair(address _pair, bool _status) external onlyAdmin {
        m_Pairs[_pair] = _status;
        m_IsDividendExempt[_pair] = _status;
    }

    function initialPair() external view returns (address) {
        return m_Pair;
    }
    
    function setInitialBlockLimit(uint256 _blocks) external onlyAdmin {
        require(_blocks > 0, "Blocks should be greater than 0");
        m_InitialBlockLimit = _blocks;
    }

    function setBuyTxLimit(uint256 _amount) external onlyAdmin {
        m_MaxBuyAmount = _amount;
    }
    
    function setSellTxLimit(uint256 _amount) external onlyAdmin {
        m_MaxSellAmount = _amount;
    }
    
    function setBot(address _address, bool _toggle) external onlyAdmin {
        m_IsBot[_address] = _toggle;
        _setIsDividendExempt(_address, _toggle);
    }
    
    function isBot(address _address) external view onlyAdmin returns (bool) {
        return m_IsBot[_address];
    }
    
    function _setIsDividendExempt(address _holder, bool _exempt) internal {
        require(_holder != address(this) && !_isPair(_holder));
        m_IsDividendExempt[_holder] = _exempt;
        if(_exempt){
            m_Distributor.setShare(_holder, 0);
        }else{
            m_Distributor.setShare(_holder, m_Balances[_holder]);
        }
    }

    function setIsDividendExempt(address _holder, bool _exempt) external onlyAdmin {
        _setIsDividendExempt(_holder, _exempt);
    }

    function setIsFeeExempt(address _holder, bool _exempt) external onlyAdmin {
        m_IsFeeExempt[_holder] = _exempt;
    }

    function setIsTxLimitExempt(address _holder, bool _exempt) external onlyAdmin {
        m_IsTxLimitExempt[_holder] = _exempt;
    }

    function setFees(uint256 _reflectionFee, uint256 _teamFee, uint256 _feeDenominator) external onlyAdmin {
        m_ReflectionFee = _reflectionFee;
        m_TeamFee = _teamFee;
        m_TotalFee = _reflectionFee.add(_teamFee);
        m_FeeDenominator = _feeDenominator;
        //Total fees has to be less than 50%
        require(m_TotalFee < m_FeeDenominator/2);
    }

    function setFeeReceiver(address _teamReceiver) external onlyAdmin {
        m_TeamReceiver = _teamReceiver;
    }
    
    function manualSend() external onlyAdmin {
        uint256 _contractETHBalance = address(this).balance;
        payable(m_TeamReceiver).transfer(_contractETHBalance);
    }

    function setSwapBackSettings(bool _enabled, uint256 _amount) external onlyAdmin {
        m_SwapEnabled = _enabled;
        m_SwapThreshold = _amount;
    }
    
    function claimDividend() external {
        m_Distributor.claimDividend(msg.sender);
    }
    
    function claimDividend(address _holder) external onlyAdmin {
        m_Distributor.claimDividend(_holder);
    }
    
    function getUnpaidEarnings(address _shareholder) public view returns (uint256) {
        return m_Distributor.getUnpaidEarnings(_shareholder);
    }

    function manualBurn(uint256 _amount) external onlyAdmin returns (bool) {
        return _basicTransfer(address(this), DEAD, _amount);
    }
    
    function getCirculatingSupply() public view returns (uint256) {
        return m_TotalSupply.sub(balanceOf(DEAD)).sub(balanceOf(ZERO));
    }
    
    function setTransferOutLimitPeriod(uint256 _period) external onlyAdmin {
        m_TransferOutLimitPeriod = _period;
    }

    function transferOutLimitPeriod() external view returns (uint256) {
        return m_TransferOutLimitPeriod;
    }
    
    function setTransferOutLimit(uint256 _limit) external onlyAdmin {
        m_TransferOutLimit = _limit;
    }

    function transferOutLimit() external view returns (uint256) {
        return m_TransferOutLimit;
    }

    function addLiquidity() external onlyAdmin {
        require(!_isLaunched(), "ALREADY_LAUNCHED");

        m_Router.addLiquidityETH(
            address(this),
            balanceOf(address(this)),
            balanceOf(address(this)),
            address(this).balance,
            m_Pair,
            block.timestamp + 60*10
        );
    }
}