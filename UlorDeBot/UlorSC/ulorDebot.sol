pragma ton-solidity >=0.35.0;
pragma AbiHeader expire;
pragma AbiHeader time;
pragma AbiHeader pubkey;

import "../Debot.sol";
import "../Terminal.sol";
import "../Menu.sol";
import "../AddressInput.sol";
import "../ConfirmInput.sol";
import "../Upgradable.sol";
import "../Sdk.sol";

struct Task {
    uint32 id;
    string text;
    uint64 createdAt;
    bool isDone;
}

struct Stat {
    uint32 completeCount;
    uint32 incompleteCount;
}

interface IMsig {
   function sendTransaction(address dest, uint128 value, bool bounce, uint8 flags, TvmCell payload  ) external;
}


abstract contract AProp {
   constructor(uint256 pubkey) public {}
}

interface IProp {
   function createTask(string text) external;
   function updateTask(uint32 id, bool done) external;
   function deleteTask(uint32 id) external;
   function getTasks() external returns (Task[] tasks);
   function getStat() external returns (Stat);
}


contract PropDebot is Debot, Upgradable {
    bytes m_icon;

    TvmCell m_propCode; // PROP contract code
    address m_address;  // PROP contract address
    Stat m_stat;        // Statistics of incompleted and completed tasks
    uint32 m_taskId;    // Task id for update. I didn't find a way to make this var local
    uint256 m_masterPubKey; // User pubkey
    address m_msigAddress;  // User wallet address

    uint32 INITIAL_BALANCE =  200000000;  // Initial PROP contract balance


    function setPropCode(TvmCell code) public {
        require(msg.pubkey() == tvm.pubkey(), 101);
        tvm.accept();
        m_propCode = code;
    }


    function onError(uint32 sdkError, uint32 exitCode) public {
        Terminal.print(0, format("Operation failed. sdkError {}, exitCode {}", sdkError, exitCode));
        _menu();
    }

    function onSuccess() public view {
        _getStat(tvm.functionId(setStat));
    }

    function start() public override {
        Terminal.input(tvm.functionId(savePublicKey),"Please enter your public key",false);
    }

    /// @notice Returns Metadata about DeBot.
    function getDebotInfo() public functionID(0xDEB) override view returns(
        string name, string version, string publisher, string key, string author,
        address support, string hello, string language, string dabi, bytes icon
    ) {
        name = "PROPERTY DeBot";
        version = "0.2.0";
        publisher = "TON Labs";
        key = "PROPERTY list manager";
        author = "ULOR";
        support = address.makeAddrStd(0, 0x66e01d6df5a8d7677d9ab2daf7f258f1e2a7fe73da5320300395f99e01dc3b5f);
        hello = "Hi, i'm a PROPERTY FOR ULOR DeBot.";
        language = "en";
        dabi = m_debotAbi.get();
        icon = m_icon;
    }

    function getRequiredInterfaces() public view override returns (uint256[] interfaces) {
        return [ Terminal.ID, Menu.ID, AddressInput.ID, ConfirmInput.ID ];
    }

    function savePublicKey(string value) public {
        (uint res, bool status) = stoi("0x"+value);
        if (status) {
            m_masterPubKey = res;

            Terminal.print(0, "Verifying if you already have Properties");
            TvmCell deployState = tvm.insertPubkey(m_propCode, m_masterPubKey);
            m_address = address.makeAddrStd(0, tvm.hash(deployState));
            Terminal.print(0, format( "Info: your Property contract address is {}", m_address));
            Sdk.getAccountType(tvm.functionId(checkStatus), m_address);

        } else {
            Terminal.input(tvm.functionId(savePublicKey),"Wrong public key. Try again!\nPlease enter your public key",false);
        }
    }


    function checkStatus(int8 acc_type) public {
        if (acc_type == 1) { // acc is active and  contract is already deployed
            _getStat(tvm.functionId(setStat));

        } else if (acc_type == -1)  { // acc is inactive
            Terminal.print(0, "You don't have Properties yet, so a new contract with an initial balance of 0.2 tokens will be deployed");
            AddressInput.get(tvm.functionId(creditAccount),"Select a wallet for payment. We will ask you to sign two transactions");

        } else  if (acc_type == 0) { // acc is uninitialized
            Terminal.print(0, format(
                "Deploying new contract. If an error occurs, check if your Properties Contract has enough tokens on its balance"
            ));
            deploy();

        } else if (acc_type == 2) {  // acc is frozen
            Terminal.print(0, format("Can not continue: account {} is frozen", m_address));
        }
    }


    function creditAccount(address value) public {
        m_msigAddress = value;
        optional(uint256) pubkey = 0;
        TvmCell empty;
        IMsig(m_msigAddress).sendTransaction{
            abiVer: 2,
            extMsg: true,
            sign: true,
            pubkey: pubkey,
            time: uint64(now),
            expire: 0,
            callbackId: tvm.functionId(waitBeforeDeploy),
            onErrorId: tvm.functionId(onErrorRepeatCredit)  // Just repeat if something went wrong
        }(m_address, INITIAL_BALANCE, false, 3, empty);
    }

    function onErrorRepeatCredit(uint32 sdkError, uint32 exitCode) public {
        // Properties: check errors if needed.
        sdkError;
        exitCode;
        creditAccount(m_msigAddress);
    }


    function waitBeforeDeploy() public  {
        Sdk.getAccountType(tvm.functionId(checkIfStatusIs0), m_address);
    }

    function checkIfStatusIs0(int8 acc_type) public {
        if (acc_type ==  0) {
            deploy();
        } else {
            waitBeforeDeploy();
        }
    }


    function deploy() private view {
            TvmCell image = tvm.insertPubkey(m_propCode, m_masterPubKey);
            optional(uint256) none;
            TvmCell deployMsg = tvm.buildExtMsg({
                abiVer: 2,
                dest: m_address,
                callbackId: tvm.functionId(onSuccess),
                onErrorId:  tvm.functionId(onErrorRepeatDeploy),    // Just repeat if something went wrong
                time: 0,
                expire: 0,
                sign: true,
                pubkey: none,
                stateInit: image,
                call: {AProp, m_masterPubKey}
            });
            tvm.sendrawmsg(deployMsg, 1);
    }


    function onErrorRepeatDeploy(uint32 sdkError, uint32 exitCode) public view {
        // Property: check errors if needed.
        sdkError;
        exitCode;
        deploy();
    }

    function setStat(Stat stat) public {
        m_stat = stat;
        _menu();
    }

    function _menu() private {
        string sep = '----------------------------------------';
        Menu.select(
            format(
                "You have {}/{}/{} (Properties Owned/Properties Sold/total) tasks",
                    m_stat.incompleteCount,
                    m_stat.completeCount,
                    m_stat.completeCount + m_stat.incompleteCount
            ),
            sep,
            [
                MenuItem("Add new Properties","",tvm.functionId(createProperty)),
                MenuItem("Show Property list","",tvm.functionId(showProperty)),
                MenuItem("Update Property status","",tvm.functionId(updateProperty)),
                MenuItem("Delete Property","",tvm.functionId(deleteProperty))
            ]
        );
    }

    function createProperty(uint32 index) public {
        index = index;
        Terminal.input(tvm.functionId(createProperty), "Please enter property ID:", false);
    }

    function createProperty(string value) public view {
        optional(uint256) pubkey = 0;
        IProp(m_address).createProperty{
                abiVer: 2,
                extMsg: true,
                sign: true,
                pubkey: pubkey,
                time: uint64(now),
                expire: 0,
                callbackId: tvm.functionId(onSuccess),
                onErrorId: tvm.functionId(onError)
            }(value);
    }

    function showProperty(uint32 index) public view {
        index = index;
        optional(uint256) none;
        IProp(m_address).getTasks{
            abiVer: 2,
            extMsg: true,
            sign: false,
            pubkey: none,
            time: uint64(now),
            expire: 0,
            callbackId: tvm.functionId(showProperty_),
            onErrorId: 0
        }();
    }

    function showProperty_( Property[] properties ) public {
        uint32 i;
        if (properties.length > 0 ) {
            Terminal.print(0, "Your Property list:");
            for (i = 0; i < properties.length; i++) {
                Property properties = properties[i];
                string completed;
                if (properties.isDone) {
                    completed = '✓';
                } else {
                    completed = ' ';
                }
                Terminal.print(0, format("{} {}  \"{}\"  at {}", properties.id, completed, properties.text, properties.createdAt));
            }
        } else {
            Terminal.print(0, "Your properties list is empty");
        }
        _menu();
    }

    function updateProperty(uint32 index) public {
        index = index;
        if (m_stat.completeCount + m_stat.incompleteCount > 0) {
            Terminal.input(tvm.functionId(updateProperty_), "Enter properties number:", false);
        } else {
            Terminal.print(0, "Sorry, you have no properties to update");
            _menu();
        }
    }

    function updateProperty_(string value) public {
        (uint256 num,) = stoi(value);
        m_taskId = uint32(num);
        ConfirmInput.get(tvm.functionId(updateProperty__),"Is this property sold?");
    }

    function updateProperty__(bool value) public view {
        optional(uint256) pubkey = 0;
        IProp(m_address).updateProperty{
                abiVer: 2,
                extMsg: true,
                sign: true,
                pubkey: pubkey,
                time: uint64(now),
                expire: 0,
                callbackId: tvm.functionId(onSuccess),
                onErrorId: tvm.functionId(onError)
            }(m_taskId, value);
    }


    function deleteProperty(uint32 index) public {
        index = index;
        if (m_stat.completeCount + m_stat.incompleteCount > 0) {
            Terminal.input(tvm.functionId(deleteProperty_), "Enter Property number:", false);
        } else {
            Terminal.print(0, "Sorry, you have no property to delete");
            _menu();
        }
    }

    function deleteProperty_(string value) public view {
        (uint256 num,) = stoi(value);
        optional(uint256) pubkey = 0;
        IProp(m_address).deleteProperty{
                abiVer: 2,
                extMsg: true,
                sign: true,
                pubkey: pubkey,
                time: uint64(now),
                expire: 0,
                callbackId: tvm.functionId(onSuccess),
                onErrorId: tvm.functionId(onError)
            }(uint32(num));
    }

    function _getStat(uint32 answerId) private view {
        optional(uint256) none;
        IProp(m_address).getStat{
            abiVer: 2,
            extMsg: true,
            sign: false,
            pubkey: none,
            time: uint64(now),
            expire: 0,
            callbackId: answerId,
            onErrorId: 0
        }();
    }

    function onCodeUpgrade() internal override {
        tvm.resetStorage();
    }
}
