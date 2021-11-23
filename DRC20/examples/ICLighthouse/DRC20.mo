/**
 * Module     : DRC20.mo
 * Author     : ICLighthouse Team
 * License    : Apache License 2.0
 * Stability  : Experimental
 * Github     : https://github.com/iclighthouse/DRC_standards/
 */

import HashMap "mo:base/HashMap";
import Principal "mo:base/Principal";
import Array "mo:base/Array";
import Option "mo:base/Option";
import Blob "mo:base/Blob";
import Nat "mo:base/Nat";
import Nat32 "mo:base/Nat32";
import Int32 "mo:base/Int32";
import Iter "mo:base/Iter";
import List "mo:base/List";
import Time "mo:base/Time";
import Deque "mo:base/Deque";
import Cycles "mo:base/ExperimentalCycles";
import Types "./types/types";
import Tools "./lib/Tools";
import Hex "./lib/Hex";
import Binary "./lib/Binary";
import SHA224 "./lib/SHA224";
import DRC202 "./lib/DRC202";

//record { totalSupply=1000000000000; decimals=8; gas=variant{token=10}; name=opt "TokenTest"; symbol=opt "TTT"; metadata=null; founder=null;} 
shared(installMsg) actor class DRC20(initArgs: Types.InitArgs) = this {
    /*
    * Types 
    */
    type Metadata = Types.Metadata;
    type Gas = Types.Gas;
    type Address = Types.Address; //Text
    type AccountId = Types.AccountId; //Blob
    type Txid = Types.Txid;  //Blob
    type TxnResult = Types.TxnResult;
    type ExecuteType = Types.ExecuteType;
    type Operation = Types.Operation;
    type Transaction = Types.Transaction;
    type TxnRecord = Types.TxnRecord;
    type Callback = Types.Callback;
    type MsgType = Types.MsgType;
    type Subscription = Types.Subscription;
    type Allowance = Types.Allowance;
    type TxnQueryRequest =Types.TxnQueryRequest;
    type TxnQueryResponse =Types.TxnQueryResponse;

    /*
    * Config 
    */
    private stable var MAX_CACHE_TIME: Int = 3 * 30 * 24 * 3600 * 1000000000; // 3 months
    private stable var MAX_CACHE_NUMBER_PER: Nat = 30; 
    private stable var FEE_TO: AccountId = Tools.blackhole();  
    private stable var STORAGE_CANISTER: Text = "oearr-eyaaa-aaaak-aabja-cai";
    private stable var MAX_PUBLICATION_TRIES: Nat = 2; 
    private stable var MAX_STORAGE_TRIES: Nat = 2; 

    /* 
    * State Variables 
    */
    private stable var standard_: Text = "DRC20 1.0"; 
    //private stable var owner: Principal = installMsg.caller; 
    private stable var name_: Text = Option.get(initArgs.name, "");
    private stable var symbol_: Text = Option.get(initArgs.symbol, "");
    private stable let decimals_: Nat8 = initArgs.decimals;
    private stable var totalSupply_: Nat = initArgs.totalSupply;
    private stable var gas_: Gas = initArgs.gas;
    private stable var metadata_: [Metadata] = Option.get(initArgs.metadata, []);
    private var txnRecords = HashMap.HashMap<Txid, TxnRecord>(1, Blob.equal, Blob.hash);
    private stable var globalTxns = Deque.empty<(Txid, Time.Time)>();
    private stable var globalLastTxns = Deque.empty<Txid>();
    private stable var index: Nat = 0;
    private var balances = HashMap.HashMap<AccountId, Nat>(1, Blob.equal, Blob.hash);
    private var nonces = HashMap.HashMap<AccountId, Nat>(1, Blob.equal, Blob.hash);
    private var lastTxns_ = HashMap.HashMap<AccountId, Deque.Deque<Txid>>(1, Blob.equal, Blob.hash); //from to caller
    private var lockedTxns_ = HashMap.HashMap<AccountId, [Txid]>(1, Blob.equal, Blob.hash); //from
    private var allowances = HashMap.HashMap<AccountId, HashMap.HashMap<AccountId, Nat>>(1, Blob.equal, Blob.hash);
    private var subscriptions = HashMap.HashMap<AccountId, Subscription>(1, Blob.equal, Blob.hash);
    private var cyclesBalances = HashMap.HashMap<AccountId, Nat>(1, Blob.equal, Blob.hash);
    private stable var storageRecords = List.nil<(Txid, Nat)>();
    private stable var publishMessages = List.nil<(AccountId, MsgType, Txid, Nat)>();
    
    /* 
    * Local Functions
    */
    // private func _onlyOwner(_caller: Principal) : Bool { 
    //     return _caller == owner;
    // };  // assert(_onlyOwner(msg.caller));
    private func _getTxnRecord(_txid: Txid): ?TxnRecord{
        return txnRecords.get(_txid);
    };
    private func _insertTxnRecord(_txn: TxnRecord): (){
        var txid = _txn.txid;
        txnRecords.put(txid, _txn);
        _pushGlobalTxns(txid);
    };
    private func _deleteTxnRecord(_txid: Txid, _isDeep: Bool): (){
        switch(txnRecords.get(_txid)){
            case(?(record)){ //Existence record
                var caller = Tools.principalToAccountBlob(record.caller);
                var from = record.transaction.from;
                var to = record.transaction.to;
                var timestamp = record.timestamp;
                if (not(_inLockedTxns(_txid, from))){ //Not in from's LockedTxns
                    if (Time.now() - timestamp > MAX_CACHE_TIME){ //Expired
                        txnRecords.delete(_txid);
                    } else if (_isDeep and not(_inLastTxns(_txid, caller)) and 
                        not(_inLastTxns(_txid, from)) and not(_inLastTxns(_txid, to))) {
                        //If isDeep=true: Not expired, not in caller, from, to's LastTxns
                        switch(record.transaction.operation){
                            case(#lockTransfer(v)){ //Not in decider's LastTxns
                                if (not(_inLastTxns(_txid, v.decider))){
                                    txnRecords.delete(_txid);
                                };
                            };
                            case(_){
                                txnRecords.delete(_txid);
                            };
                        };
                    };
                };
            };
            case(_){};
        };
    };
    private func _getAccountId(_address: Address): AccountId{
        switch (Tools.accountHexToAccountBlob(_address)){
            case(?(a)){
                return a;
            };
            case(_){
                var p = Principal.fromText(_address);
                var a = Tools.principalToAccountBlob(p);
                return a;
            };
        };
    }; 
    private func _getAccountIdFromPrincipal(_p: Principal): AccountId{
        var a = Tools.principalToAccountBlob(_p);
        return a;
    }; // AccountIdToPrincipal: accountMaps.get(_a)
    private stable let founder_: AccountId = _getAccountId(Option.get(initArgs.founder, Principal.toText(installMsg.caller)));
    private func _getTxid(_caller: AccountId): Txid{
        var _nonce: Nat = _getNonce(_caller);
        return DRC202.generateTxid(Principal.fromActor(this), _caller, _nonce);
    };
    private func _getBalance(_a: AccountId): Nat{
        switch(balances.get(_a)){
            case(?(balance)){
                return balance;
            };
            case(_){
                return 0;
            };
        };
    };
    private func _setBalance(_a: AccountId, _v: Nat): (){
        if(_v == 0){
            balances.delete(_a);
        } else {
            switch (gas_){
                case(#token(fee)){
                    if (_v <= fee){
                        balances.delete(_a);
                    } else{
                        balances.put(_a, _v);
                    };
                };
                case(_){
                    balances.put(_a, _v);
                };
            }
        };
    };
    private func _getNonce(_a: AccountId): Nat{
        switch(nonces.get(_a)){
            case(?(nonce)){
                return nonce;
            };
            case(_){
                return 0;
            };
        };
    };
    private func _addNonce(_a: AccountId): (){
        var n = _getNonce(_a);
        nonces.put(_a, n+1);
        index += 1;
    };
    private func _pushGlobalTxns(_txid: Txid): (){
        // push new txid.
        globalTxns := Deque.pushFront(globalTxns, (_txid, Time.now()));
        globalLastTxns := Deque.pushFront(globalLastTxns, _txid);
        var size = List.size(globalLastTxns.0) + List.size(globalLastTxns.1);
        while (size > MAX_CACHE_NUMBER_PER * 5){
            size -= 1;
            switch (Deque.popBack(globalLastTxns)){
                case(?(q, v)){
                    globalLastTxns := q;
                };
                case(_){};
            };
        };
        // pop expired txids, and delete their records.
        switch(Deque.peekBack(globalTxns)){
            case (?(txid, ts)){
                var timestamp: Time.Time = ts;
                while (Time.now() - timestamp > MAX_CACHE_TIME){
                    switch (Deque.popBack(globalTxns)){
                        case(?(q, v)){
                            globalTxns := q;
                            _deleteTxnRecord(v.0, false); // delete the record.
                        };
                        case(_){};
                    };
                    switch(Deque.peekBack(globalTxns)){
                        case(?(txid_,ts_)){
                            timestamp := ts_;
                        };
                        case(_){
                            timestamp := Time.now();
                        };
                    };
                };
            };
            case(_){};
        };
    };
    private func _getGlobalLastTxns(): [Txid]{
        var l = List.append(globalLastTxns.0, List.reverse(globalLastTxns.1));
        return List.toArray(l);
    };
    private func _inLastTxns(_txid: Txid, _a: AccountId): Bool{
        switch(lastTxns_.get(_a)){
            case(?(txidsQ)){
                var l = List.append(txidsQ.0, List.reverse(txidsQ.1));
                if (List.some(l, func (v: Txid): Bool { if (v == _txid) true  else false; })){
                    return true;
                } else {
                    return false;
                };
            };
            case(_){
                return false;
            };
        };
    };
    private func _getLastTxns(_a: AccountId): [Txid]{
        switch(lastTxns_.get(_a)){
            case(?(txidsQ)){
                var l = List.append(txidsQ.0, List.reverse(txidsQ.1));
                return List.toArray(l);
            };
            case(_){
                return [];
            };
        };
    };
    private func _cleanLasTxns(_a: AccountId): (){
        switch(lastTxns_.get(_a)){
            case(?(q)){  
                var txids: Deque.Deque<Txid> = q;
                var size = List.size(txids.0) + List.size(txids.1);
                while (size > MAX_CACHE_NUMBER_PER){
                    size -= 1;
                    switch (Deque.popBack(txids)){
                        case(?(q, v)){
                            txids := q;
                            switch(Deque.peekFront(txids)){
                                case(?(v)){};
                                case(_){
                                    lastTxns_.delete(_a);
                                };
                            };
                        };
                        case(_){};
                    };
                };
                lastTxns_.put(_a, txids);
            };
            case(_){};
        };
    };
    private func _pushLastTxn(_as: [AccountId], _txid: Txid): (){
        for (_a in _as.vals()){
            var count: Nat = 0;
            for (_a2 in _as.vals()){
                if (Blob.equal(_a, _a2)){ count += 1; };
            };
            if (count == 1){
                switch(lastTxns_.get(_a)){
                    case(?(q)){
                        var txids: Deque.Deque<Txid> = q;
                        txids := Deque.pushFront(txids, _txid);
                        lastTxns_.put(_a, txids);
                        _cleanLasTxns(_a);
                    };
                    case(_){
                        var new = Deque.empty<Txid>();
                        new := Deque.pushFront(new, _txid);
                        lastTxns_.put(_a, new);
                    };
                };
            };
        };
    };
    private func _inLockedTxns(_txid: Txid, _a: AccountId): Bool{
        switch(lockedTxns_.get(_a)){
            case(?(txids)){
                switch (Array.find(txids, func (v: Txid): Bool { if (v == _txid) true else false; })){
                    case(?(v)){
                        return true;
                    };
                    case(_){
                        return false;
                    };
                };
            };
            case(_){
                return false;
            };
        };
    };
    private func _getLockedTxns(_a: AccountId): [Txid]{
        switch(lockedTxns_.get(_a)){
            case(?(txids)){
                return txids;
            };
            case(_){
                return [];
            };
        };
    };
    private func _appendLockedTxn(_a: AccountId, _txid: Txid): (){
        switch(lockedTxns_.get(_a)){
            case(?(arr)){
                var txids: [Txid] = arr;
                txids := Array.append([_txid], txids);
                lockedTxns_.put(_a, txids);
            };
            case(_){
                lockedTxns_.put(_a, [_txid]);
            };
        };
    };
    private func _dropLockedTxn(_a: AccountId, _txid: Txid): (){
        switch(lockedTxns_.get(_a)){
            case(?(arr)){
                var txids: [Txid] = arr;
                txids := Array.filter(txids, func (t: Txid): Bool {
                    if (t == _txid){ return false; } 
                    else { return true; };
                });
                if (txids.size() == 0){
                    lockedTxns_.delete(_a);
                };
                lockedTxns_.put(_a, txids);
                _deleteTxnRecord(_txid, true);
            };
            case(_){};
        };
    };
    private func _getAllowances(_a: AccountId): [Allowance]{
        switch(allowances.get(_a)){
            case(?(allowHashMap)){
                var a = Iter.map(allowHashMap.entries(), func (entry: (AccountId, Nat)): Allowance{
                    return { spender = entry.0; remaining = entry.1; };
                });
                return Iter.toArray(a);
            };
            case(_){
                return [];
            };
        };
    };
    private func _getAllowance(_a: AccountId, _s: AccountId): Nat{
        switch(allowances.get(_a)){
            case(?(hm)){
                switch(hm.get(_s)){
                    case(?(v)){
                        return v;
                    };
                    case(_){
                        return 0;
                    };
                };
            };
            case(_){
                return 0;
            };
        };
    };
    private func _setAllowance(_a: AccountId, _s: AccountId, _v: Nat): (){
        switch(allowances.get(_a)){
            case(?(hm)){
                if (_v > 0){
                    hm.put(_s, _v);
                } else {
                    hm.delete(_s);
                };
                //allowances.put(_a, hm);
                if (hm.size() == 0){
                    allowances.delete(_a);
                };
            };
            case(_){
                if (_v > 0){
                    var new = HashMap.HashMap<AccountId, Nat>(1, Blob.equal, Blob.hash);
                    new.put(_s, _v);
                    allowances.put(_a, new);
                };
            };
        };
    };
    private func _getSubscription(_a: AccountId): ?Subscription{
        return subscriptions.get(_a);
    };
    private func _getSubCallback(_a: AccountId, _mt: MsgType): ?Callback{
        switch(subscriptions.get(_a)){
            case(?(sub)){
                var msgTypes = sub.msgTypes;
                var found = Array.find(msgTypes, func (mt: MsgType): Bool{
                    if (mt == _mt){
                        return true;
                    } else { 
                        return false; 
                    };
                });
                switch(found){
                    case(?(v)){ return ?sub.callback; };
                    case(_){ return null; };
                };
            };
            case(_){
                return null;
            };
        };
    };
    private func _setSubscription(_a: AccountId, _sub: Subscription): (){
        if (_sub.msgTypes.size() == 0){
            subscriptions.delete(_a);
        } else{
            subscriptions.put(_a, _sub);
        };
    };
    // pushMessages
    private func _pushMessages(_subs: [AccountId], _msgType: MsgType, _txid: Txid) : (){
        for (a in _subs.vals()){
            var count: Nat = 0;
            for (a2 in _subs.vals()){
                if (Blob.equal(a, a2)){ count += 1; };
            };
            if (count == 1){
                publishMessages := List.push((a, _msgType, _txid, 0), publishMessages);
            };
        };
    };
    // publish
    private func _publish() : async (){
        var _publishMessages = List.nil<(AccountId, MsgType, Txid, Nat)>();
        var item = List.pop(publishMessages);
        while (Option.isSome(item.0)){
            switch(item.0){
                case(?(account, msgType, txid, callCount)){
                    switch(_getSubCallback(account, msgType)){
                        case(?(callback)){
                            if (callCount < MAX_PUBLICATION_TRIES){
                                switch(_getTxnRecord(txid)){
                                    case(?(txn)){
                                        try{
                                            await callback(txn);
                                        } catch(e){ //push
                                            _publishMessages := List.push((account, msgType, txid, callCount+1), _publishMessages);
                                        };
                                    };
                                    case(_){};
                                };
                            };
                        };
                        case(_){};
                    };
                };
                case(_){};
            };
            item := List.pop(item.1);
        };
        publishMessages := _publishMessages;
    };

    private func _chargeFee(_caller: AccountId, _percent: Nat, _isCheck: Bool): Bool{
        let cyclesAvailable = Cycles.available(); 
        switch(gas_){
            case(#cycles(v)){
                if(v > 0) {
                    let fee = Nat.max(v * _percent / 100, 1);
                    if (cyclesAvailable >= fee){
                        if (not(_isCheck)) { 
                            let accepted = Cycles.accept(fee); 
                            switch(cyclesBalances.get(FEE_TO)){
                                case(?(balance2)){ cyclesBalances.put(FEE_TO, balance2 + accepted); };
                                case(_){ cyclesBalances.put(FEE_TO, accepted); };
                            };
                        };
                        return true;
                    } else {
                        switch(cyclesBalances.get(_caller)){
                            case(?(balance)){
                                if (balance >= fee){
                                    if (not(_isCheck)) { 
                                        cyclesBalances.put(_caller, balance - fee); 
                                        switch(cyclesBalances.get(FEE_TO)){
                                            case(?(balance2)){ cyclesBalances.put(FEE_TO, balance2 + fee); };
                                            case(_){ cyclesBalances.put(FEE_TO, fee); };
                                        };
                                    };
                                    return true;
                                } else {
                                    if (not(_isCheck)) { cyclesBalances.delete(_caller); };
                                    return false;
                                };
                            };
                            case(_){
                                return false;
                            };
                        };
                    };
                };
                return true;
            };
            case(#token(v)){ 
                if(v > 0) {
                    let fee = Nat.max(v * _percent / 100, 1);
                    if (_getBalance(_caller) >= fee){
                        if (not(_isCheck)) { ignore _send(_caller, FEE_TO, fee, false); };
                        return true;
                    } else {
                        return false;
                    };
                };
                return true;
            };
            case(_){ return true; };
        };
    };
    private func _send(_from: AccountId, _to: AccountId, _value: Nat, _isCheck: Bool): Bool{
        var balance_from = _getBalance(_from);
        if (balance_from >= _value){
            if (not(_isCheck)) { 
                balance_from -= _value;
                _setBalance(_from, balance_from);
                var balance_to = _getBalance(_to);
                balance_to += _value;
                _setBalance(_to, balance_to);
            };
            return true;
        } else {
            return false;
        };
    };
    private func _mint(_to: AccountId, _value: Nat): Bool{
        var balance_to = _getBalance(_to);
        balance_to += _value;
        _setBalance(_to, balance_to);
        totalSupply_ += _value;
        return true;
    };
    private func _burn(_from: AccountId, _value: Nat, _isCheck: Bool): Bool{
        var balance_from = _getBalance(_from);
        if (balance_from >= _value){
            if (not(_isCheck)) { 
                balance_from -= _value;
                _setBalance(_from, balance_from);
                totalSupply_ -= _value;
            };
            return true;
        } else {
            return false;
        };
    };
    private func _lock(_from: AccountId, _value: Nat, _isCheck: Bool): Bool{
        var balance_from = _getBalance(_from);
        if (balance_from >= _value){
            if (not(_isCheck)) { 
                balance_from -= _value;
                _setBalance(_from, balance_from);
            };
            return true;
        } else {
            return false;
        };
    };
    private func _execute(_from: AccountId, _to: AccountId, _value: Nat, _fallback: Nat): Bool{
        var balance_from = _getBalance(_from) + _fallback;
        _setBalance(_from, balance_from);
        var balance_to = _getBalance(_to) + _value;
        _setBalance(_to, balance_to);
        return true;
    };
    // Do not update state variables before calling _transfer
    private func _transfer(_msgCaller: Principal, _from: AccountId, _to: AccountId, _value: Nat, _data: ?Blob, 
    _operation: Operation, _isAllowance: Bool): (result: TxnResult) {
        let callerPrincipal = _msgCaller;
        let caller = _getAccountIdFromPrincipal(_msgCaller);
        let txid = _getTxid(caller);
        let from = _from;
        let to = _to;
        let value = _value; 
        var allowed: Nat = 0; // *
        var spendValue = _value; // *
        if (_isAllowance){
            allowed := _getAllowance(from, caller);
        };
        // check and operate
        switch(_operation){
            case(#transfer(operation)){
                switch(operation.action){
                    case(#send){
                        if (not(_send(from, to, value, true))){
                            return #err({ code=#InsufficientBalance; message="Insufficient Balance"; });
                        } else if (_isAllowance and allowed < spendValue){
                            return #err({ code=#InsufficientAllowance; message="Insufficient Allowance"; });
                        };
                        ignore _send(from, to, value, false);
                        var as: [AccountId] = [from, to];
                        if (_isAllowance and spendValue > 0){
                            _setAllowance(from, caller, allowed - spendValue);
                            as := Array.append(as, [caller]);
                        };
                        _pushLastTxn(as, txid); 
                        _pushMessages(as, #onTransfer, txid);
                    };
                    case(#mint){
                        ignore _mint(to, value);
                        var as: [AccountId] = [to];
                        _pushLastTxn(as, txid); 
                        as := Array.append(as, [caller]);
                        _pushMessages(as, #onTransfer, txid);
                    };
                    case(#burn){
                        if (not(_burn(from, value, true))){
                            return #err({ code=#InsufficientBalance; message="Insufficient Balance"; });
                        } else if (_isAllowance and allowed < spendValue){
                            return #err({ code=#InsufficientAllowance; message="Insufficient Allowance"; });
                        };
                        ignore _burn(from, value, false);
                        var as: [AccountId] = [from];
                        if (_isAllowance and spendValue > 0){
                            _setAllowance(from, caller, allowed - spendValue);
                            as := Array.append(as, [caller]);
                        };
                        _pushLastTxn(as, txid); 
                        _pushMessages(as, #onTransfer, txid);
                    };
                };
            };
            case(#lockTransfer(operation)){
                spendValue := operation.locked;
                if (not(_lock(from, operation.locked, true))){
                    return #err({ code=#InsufficientBalance; message="Insufficient Balance"; });
                } else if (_isAllowance and allowed < spendValue){
                    return #err({ code=#InsufficientAllowance; message="Insufficient Allowance"; });
                };
                ignore _lock(from, operation.locked, false);
                var as: [AccountId] = [from, to, operation.decider];
                if (_isAllowance and spendValue > 0){
                    _setAllowance(from, caller, allowed - spendValue);
                    as := Array.append(as, [caller]);
                };
                _pushLastTxn(as, txid);
                _pushMessages(as, #onLock, txid);
                _appendLockedTxn(from, txid);
            };
            case(#executeTransfer(operation)){
                spendValue := 0;
                ignore _execute(from, to, value, operation.fallback);
                var as: [AccountId] = [from, to, caller];
                _pushLastTxn(as, txid);
                _pushMessages(as, #onExecute, txid);
                _dropLockedTxn(from, operation.lockedTxid);
            };
            case(#approve(operation)){
                spendValue := 0;
                _setAllowance(from, to, operation.allowance); 
                var as: [AccountId] = [from, to];
                _pushLastTxn(as, txid);
                _pushMessages(as, #onApprove, txid);
            };
        };
        
        // insert record
        var txn: TxnRecord = {
            txid = txid;
            caller = callerPrincipal;
            timestamp = Time.now();
            index = index;
            nonce = _getNonce(caller);
            gas = gas_;
            transaction = {
                from = from;
                to = to;
                value = value; 
                operation = _operation;
                data = _data;
            };
        };
        _insertTxnRecord(txn); 
        // update nonce
        _addNonce(caller); 
        // push storageRecords
        storageRecords := List.push((txid, 0), storageRecords);
        return #ok(txid);
    };
    // records storage (DRC202 Standard)
    private func _drc202Store() : async (){
        let drc202: DRC202.Self = actor(STORAGE_CANISTER);
        var _storageRecords = List.nil<(Txid, Nat)>();
        var item = List.pop(storageRecords);
        let storageFee = await drc202.fee();
        while (Option.isSome(item.0)){
            switch(item.0){
                case(?(txid, callCount)){
                    if (callCount < MAX_STORAGE_TRIES){
                        switch(_getTxnRecord(txid)){
                            case(?(txn)){
                                try{
                                    Cycles.add(storageFee);
                                    await drc202.store(txn);
                                } catch(e){ //push
                                    _storageRecords := List.push((txid, callCount+1), _storageRecords);
                                };
                            };
                            case(_){};
                        };
                    };
                };
                case(_){};
            };
            item := List.pop(item.1);
        };
        storageRecords := _storageRecords;
    };

    /* 
    * Shared Functions
    */
    /// Returns standard name.
    public query func standard() : async Text{
        return standard_;
    };
    /// Returns the name of the token.
    public query func name() : async Text{
        return name_;
    };
    /// Returns the symbol of the token.
    public query func symbol() : async Text{
        return symbol_;
    };
    /// Returns the number of decimals the token uses.
    public query func decimals() : async Nat8{
        return decimals_;
    };
    /// Returns the extend metadata info of the token.
    public query func metadata() : async [Metadata]{
        return metadata_;
    };
    /// Sends/donates cycles to the token canister in _account's name, and return cycles balance of the account/token.
    /// If the parameter `_account` is null, it means donation.
    public shared(msg) func cyclesReceive(_account: ?Address) : async (balance: Nat){
        let amount = Cycles.available(); 
        let accepted = Cycles.accept(amount); 
        var account = FEE_TO; //_getAccountIdFromPrincipal(Principal.fromActor(this));
        switch(_account){
            case(?(a)){
                account := _getAccountId(a);
            };
            case(_){};
        };
        switch(cyclesBalances.get(account)){
            case(?(value)){
                cyclesBalances.put(account, value + accepted);
                return value + accepted;
            };
            case(_){
                cyclesBalances.put(account, accepted);
                return accepted;
            };
        };
    };
    /// Returns the cycles balance of the given account _owner in the token.
    public query func cyclesBalanceOf(_owner: Address) : async (balance: Nat){
        var account = _getAccountId(_owner);
        switch(cyclesBalances.get(account)){
            case(?(value)){
                return value;
            };
            case(_){
                return 0;
            };
        };
    };
    /// Returns the transaction fee of the token.
    public query func gas() : async Gas{
        return gas_;
    };
    /// Returns the total token supply.
    public query func totalSupply() : async Nat{
        return totalSupply_;
    };
    /// Returns the account balance of the given account _owner, not including the locked balance.
    public query func balanceOf(_owner: Address) : async (balance: Nat){
        return _getBalance(_getAccountId(_owner));
    };
    /// Transfers _value amount of tokens from caller's account to address _to, returns type TxnResult.
    public shared(msg) func transfer(_to: Address, _value: Nat, _data: ?Blob) : async (result: TxnResult) {
        let from = _getAccountIdFromPrincipal(msg.caller);
        let to = _getAccountId(_to);
        let operation: Operation = #transfer({ action = #send; });
        // Fee/2 is charged whether the transaction is successful or not
        if(not(_chargeFee(from, 50, false))){
            return #err({ code=#InsufficientGas; message="Insufficient Gas"; });
        };
        // transfer
        let res = _transfer(msg.caller, from, to, _value, _data, operation, false);
        // publish
        let pub = _publish();
        // records storage (DRC202 Standard)
        let store = _drc202Store();
        // Fee/2 is charged for the post (Ignore charging fail)
        ignore _chargeFee(from, 50, false);
        return res;
    };
    /// Transfers _value amount of tokens from address _from to address _to, returns type TxnResult.
    public shared(msg) func transferFrom(_from: Address, _to: Address, _value: Nat, _data: ?Blob) : 
    async (result: TxnResult) {
        let caller = _getAccountIdFromPrincipal(msg.caller);
        let from = _getAccountId(_from);
        let to = _getAccountId(_to);
        let operation: Operation = #transfer({ action = #send; });
        // Fee/2 is charged whether the transaction is successful or not
        if(not(_chargeFee(caller, 50, false))){
            return #err({ code=#InsufficientGas; message="Insufficient Gas"; });
        };
        // transfer
        let res = _transfer(msg.caller, from, to, _value, _data, operation, true);
        // publish
        let pub = _publish();
        // records storage (DRC202 Standard)
        let store = _drc202Store();
        // Fee/2 is charged for the post (Ignore charging fail)
        ignore _chargeFee(caller, 50, false);
        return res;
    };
    /// Locks a transaction, specifies a `_decider` who can decide the execution of this transaction, 
    /// and sets an expiration period `_timeout` seconds after which the locked transaction will be unlocked.
    /// The parameter _timeout should not be greater than 1000000 seconds.
    public shared(msg) func lockTransfer(_to: Address, _value: Nat, _timeout: Nat32, 
    _decider: ?Address, _data: ?Blob) : async (result: TxnResult) {
        if (_timeout > 1000000){
            return #err({ code=#UndefinedError; message="_timeout should not be greater than 1000000 seconds."; });
        };
        var decider: AccountId = _getAccountIdFromPrincipal(msg.caller);
        switch(_decider){
            case(?(v)){ decider := _getAccountId(v); };
            case(_){};
        };
        let operation: Operation = #lockTransfer({ 
            locked = _value;  // be locked for the amount
            expiration = Time.now() + Int32.toInt(Int32.fromNat32(_timeout)) * 1000000000;  
            decider = decider;
        });
        let from = _getAccountIdFromPrincipal(msg.caller);
        let to = _getAccountId(_to);
        // Fee/2 is charged whether the transaction is successful or not
        if(not(_chargeFee(from, 50, false))){
            return #err({ code=#InsufficientGas; message="Insufficient Gas"; });
        };
        // transfer
        let res = _transfer(msg.caller, from, to, 0, _data, operation, false);
        // publish
        let pub = _publish();
        // records storage (DRC202 Standard)
        let store = _drc202Store();
        // Fee/2 is charged for the post (Ignore charging fail)
        ignore _chargeFee(from, 50, false);
        return res;
    };
    /// `spender` locks a transaction.
    public shared(msg) func lockTransferFrom(_from: Address, _to: Address, _value: Nat, 
    _timeout: Nat32, _decider: ?Address, _data: ?Blob) : async (result: TxnResult) {
        if (_timeout > 1000000){
            return #err({ code=#UndefinedError; message="_timeout should not be greater than 1000000 seconds."; });
        };
        var decider: AccountId = _getAccountIdFromPrincipal(msg.caller);
        switch(_decider){
            case(?(v)){ decider := _getAccountId(v); };
            case(_){};
        };
        let operation: Operation = #lockTransfer({ 
            locked = _value;  // be locked for the amount
            expiration = Time.now() + Int32.toInt(Int32.fromNat32(_timeout)) * 1000000000;  
            decider = decider;
        });
        let caller = _getAccountIdFromPrincipal(msg.caller);
        let from = _getAccountId(_from);
        let to = _getAccountId(_to);
        // Fee/2 is charged whether the transaction is successful or not
        if(not(_chargeFee(caller, 50, false))){
            return #err({ code=#InsufficientGas; message="Insufficient Gas"; });
        };
        // transfer
        let res = _transfer(msg.caller, from, to, 0, _data, operation, true);
        // publish
        let pub = _publish();
        // records storage (DRC202 Standard)
        let store = _drc202Store();
        // Fee/2 is charged for the post (Ignore charging fail)
        ignore _chargeFee(caller, 50, false);
        return res;
    };
    /// The `decider` executes the locked transaction `_txid`, or the `owner` can fallback the locked transaction after the lock has expired.
    public shared(msg) func executeTransfer(_txid: Txid, _executeType: ExecuteType) : async (result: TxnResult) {
        let txid = _txid;
        let caller = _getAccountIdFromPrincipal(msg.caller);
        // Fee/2 is charged whether the transaction is successful or not
        if(not(_chargeFee(caller, 50, false))){
            return #err({ code=#InsufficientGas; message="Insufficient Gas"; });
        };
        switch(_getTxnRecord(txid)){
            case(?(txn)){
                let from = txn.transaction.from;
                let to = txn.transaction.to;
                if (not(_inLockedTxns(txid, from))){
                    return #err({ code=#UndefinedError; message="The transaction isn't in locked"; });
                };
                switch(txn.transaction.operation){
                    case(#lockTransfer(v)){
                        let locked = v.locked;
                        let expiration = v.expiration;
                        let decider = v.decider;
                        var fallback: Nat = 0;
                        switch(_executeType){
                            case(#fallback){
                                if (not( caller == decider or (Time.now() > expiration and caller == from) )) {
                                    return #err({ code=#UndefinedError; message="No Permission"; });
                                };
                                fallback := locked;
                            };
                            case(#sendAll){
                                if (Time.now() > expiration){
                                    return #err({ code=#LockedTransferExpired; message="Locked Transfer Expired"; });
                                };
                                if (caller != decider){
                                    return #err({ code=#UndefinedError; message="No Permission"; });
                                };
                            };
                            case(#sendAndFallback(v)){
                                if (Time.now() > expiration){
                                    return #err({ code=#LockedTransferExpired; message="Locked Transfer Expired"; });
                                };
                                if (caller != decider){
                                    return #err({ code=#UndefinedError; message="No Permission"; });
                                };
                                fallback := v;
                            };
                        };
                        var value: Nat = 0;
                        if (locked > fallback){
                            value := locked - fallback;
                        };
                        let operation: Operation = #executeTransfer({ 
                            lockedTxid = txid;  
                            fallback = fallback;
                        });
                        let res = _transfer(msg.caller, from, to, value, null, operation, false);
                        // publish
                        let pub = _publish();
                        // records storage (DRC202 Standard)
                        let store = _drc202Store();
                        // Fee/2 is charged for the post (Ignore charging fail)
                        ignore _chargeFee(caller, 50, false);
                        return res;
                    };
                    case(_){
                        return #err({ code=#UndefinedError; message="The status of the transaction record is not locked"; });
                    };
                };
            };
            case(_){
                return #err({ code=#UndefinedError; message="No transaction record exists"; });
            };
        };
    };
    /// Queries the transaction records information.
    public query func txnQuery(_request: TxnQueryRequest) : async (response: TxnQueryResponse){
        switch(_request){
            case(#txnCountGlobal){
                return #txnCountGlobal(index);
            };
            case(#txnCount(args)){
                var account = _getAccountId(args.owner);
                return #txnCount(_getNonce(account));
            };
            case(#getTxn(args)){
                return #getTxn(_getTxnRecord(args.txid));
            };
            case(#lastTxidsGlobal){
                return #lastTxidsGlobal(_getGlobalLastTxns());
            };
            case(#lastTxids(args)){
                return #lastTxids(_getLastTxns(_getAccountId(args.owner)));
            };
            case(#lockedTxns(args)){
                var txids = _getLockedTxns(_getAccountId(args.owner));
                var lockedBalance: Nat = 0;
                var txns: [TxnRecord] = [];
                for (txid in txids.vals()){
                    switch(_getTxnRecord(txid)){
                        case(?(record)){
                            switch(record.transaction.operation){
                                case(#lockTransfer(v)){
                                    lockedBalance += v.locked;
                                };
                                case(_){};
                            };
                            txns := Array.append(txns, [record]);
                        };
                        case(_){};
                    };
                };
                return #lockedTxns({ lockedBalance = lockedBalance; txns = txns; });   
            };
        };
    };

    /// Subscribes to the token's messages, giving the callback function and the types of messages as parameters.
    public shared(msg) func subscribe(_callback: Callback, _msgTypes: [MsgType]) : async Bool{
        let caller = _getAccountIdFromPrincipal(msg.caller);
        assert(_chargeFee(caller, 100, false));
        let sub: Subscription = {
            callback = _callback;
            msgTypes = _msgTypes;
        };
        _setSubscription(caller, sub);
        return true;
    };
    /// Returns the subscription status of the subscriber `_owner`. 
    public query func subscribed(_owner: Address) : async (result: ?Subscription){
        return _getSubscription(_getAccountId(_owner));
    };
    /// Allows `_spender` to withdraw from your account multiple times, up to the `_value` amount.
    /// If this function is called again it overwrites the current allowance with `_value`. 
    public shared(msg) func approve(_spender: Address, _value: Nat) : async (result: TxnResult){
        let from = _getAccountIdFromPrincipal(msg.caller);
        let to = _getAccountId(_spender);
        let operation: Operation = #approve({ allowance = _value; });
        // Fee/2 is charged whether the transaction is successful or not
        if(not(_chargeFee(from, 50, false))){
            return #err({ code=#InsufficientGas; message="Insufficient Gas"; });
        };
        // transfer
        let res = _transfer(msg.caller, from, to, 0, null, operation, false);
        // publish
        let pub = _publish();
        // records storage (DRC202 Standard)
        let store = _drc202Store();
        // Fee/2 is charged for the post (Ignore charging fail)
        ignore _chargeFee(from, 50, false);
        return res;
    };
    /// Returns the amount which `_spender` is still allowed to withdraw from `_owner`.
    public query func allowance(_owner: Address, _spender: Address) : async (remaining: Nat) {
        return _getAllowance(_getAccountId(_owner), _getAccountId(_spender));
    };
    /// Returns all your approvals with a non-zero amount.
    public query func approvals(_owner: Address) : async (allowances: [Allowance]) {
        return _getAllowances(_getAccountId(_owner));
    };

    /* 
    * Genesis
    */
    private stable var genesisCreated: Bool = false;
    if (not(genesisCreated)){
        balances.put(founder_, totalSupply_);
        var txn: TxnRecord = {
            txid = Blob.fromArray([0:Nat8,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]);
            caller = installMsg.caller;
            timestamp = Time.now();
            index = index;
            nonce = 0;
            gas = #noFee;
            transaction = {
                from = Tools.blackhole();
                to = founder_;
                value = totalSupply_; 
                operation = #transfer({ action = #mint; });
                data = null;
            };
        };
        index += 1;
        nonces.put(Tools.principalToAccountBlob(installMsg.caller), 1);
        txnRecords.put(txn.txid, txn);
        globalTxns := Deque.pushFront(globalTxns, (txn.txid, Time.now()));
        globalLastTxns := Deque.pushFront(globalLastTxns, txn.txid);
        lastTxns_.put(founder_, Deque.pushFront(Deque.empty<Txid>(), txn.txid));
        genesisCreated := true;
        // push storageRecords
        storageRecords := List.push((txn.txid, 0), storageRecords);
    };

};