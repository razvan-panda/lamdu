/* jshint node: true */
/* jshint esversion: 6 */
"use strict";

process.stdout._handle.setBlocking(true);

var conf = require('./rtsConfig.js');

// Tag names must match those in Lamdu.Builtins.Anchors
var trueTag = conf.builtinTagName('true');
var falseTag = conf.builtinTagName('false');
var objTag = conf.builtinTagName('object');
var infixlTag = conf.builtinTagName('infixl');
var infixrTag = conf.builtinTagName('infixr');
var indexTag = conf.builtinTagName('index');
var startTag = conf.builtinTagName('start');
var stopTag = conf.builtinTagName('stop');
var valTag = conf.builtinTagName('val');
var oldPathTag = conf.builtinTagName('oldPath');
var newPathTag = conf.builtinTagName('newPath');
var filePathTag = conf.builtinTagName('filePath');
var fileDescTag = conf.builtinTagName('fileDesc');
var dataTag = conf.builtinTagName('data');
var modeTag = conf.builtinTagName('mode');
var sizeTag = conf.builtinTagName('size');
var srcPathTag = conf.builtinTagName('srcPath');
var dstPathTag = conf.builtinTagName('dstPath');
var flagsTag = conf.builtinTagName('flags');
var hostTag = conf.builtinTagName('host');
var portTag = conf.builtinTagName('port');
var userTag = conf.builtinTagName('user');
var passwordTag = conf.builtinTagName('password');
var databaseTag = conf.builtinTagName('database');
var fieldsTag = conf.builtinTagName('fields');
var exclusiveTag = conf.builtinTagName('exclusive');
var connectionHandlerTag = conf.builtinTagName('connectionHandler');
var socketTag = conf.builtinTagName('socket');
var errorTag = conf.builtinTagName('error');
var successTag = conf.builtinTagName('success');

var bool = function (x) {
    return {tag: x ? trueTag : falseTag, data: {}};
};

// Assumes "a" and "b" are of same type, and it is an object created by
// Lamdu's JS backend - this need not work for all JS objects..
var isEqual = function (a, b) {
    if (a == b)
        return true;
    if (typeof a != 'object')
        return a == b;
    if (a.length != b.length)
        return false;
    for (var p in a)
        if (p != 'cacheId' && !isEqual(a[p], b[p]))
            return false;
    return true;
};

var bytes = function (list) {
    return new Uint8Array(list);
};

var bytesFromAscii = function (str) {
    var arr = new Uint8Array(str.length);
    for (var i = 0; i < str.length; ++i) {
        arr[i] = str.charCodeAt(i);
    }
    return arr;
};

var encode = function() {
    var cacheId = 0;
    return function (x) {
        var replacer = function(key, value) {
            if (value == null) { // or undefined due to auto-coercion
                return {};
            }
            if (typeof value == "number" && !isFinite(value)) {
                return { "number": String(value) };
            }
            if ((typeof value != "object" && typeof value != "function") ||
                key === "array" || key === "bytes") {
                return value;
            }
            if (value.hasOwnProperty("cacheId")) {
                if (value.cacheId == -1) {
                    // Opaque value
                    return {};
                }
                return { cachedVal: value.cacheId };
            }
            value.cacheId = cacheId++;
            if (Function.prototype.isPrototypeOf(value)) {
                return { func: value.cacheId };
            }
            if (Array.prototype.isPrototypeOf(value)) {
                return {
                    array: value,
                    cacheId: value.cacheId,
                };
            }
            if (Uint8Array.prototype.isPrototypeOf(value)) {
                return {
                    bytes: Array.from(value),
                    cacheId: value.cacheId,
                };
            }
            return value;
        };
        return JSON.stringify(x, replacer);
    };
}();

var toString = function (bytes) {
    // This is a nodejs only method to convert a UInt8Array to a string.
    // For the browser we'll need to augment this.
    return Buffer(bytes).toString();
};

var makeOpaque = function (obj) {
    obj.cacheId = -1;
};

var mutFunc = function (inner) {
    return function(x) {
        return function(cont) {
            return cont(inner(x));
        };
    };
};

// Create a parameterized Mut action which returns nothing (void),
// from a call with a nodejs callback which may get an error.
var mutVoidWithError = function (inner) {
    return function(x) {
        return function(cont) {
            inner(x)(err => {
                if (err) throw err;
                cont({});
            });
        };
    };
};

module.exports = {
    logRepl: conf.logRepl,
    logResult: function (scope, exprId, result) {
        process.stdout.write(encode({
            event:"Result",
            scope:scope,
            exprId:exprId,
            result:result
            }));
        process.stdout.write("\n");
        return result;
    },
    logNewScope: function (parentScope, scope, lamId, arg) {
        process.stdout.write(encode({
            event:"NewScope",
            parentScope:parentScope,
            scope:scope,
            lamId:lamId,
            arg:arg
            }));
        process.stdout.write("\n");
    },
    wrap: function (fast, slow) {
        var count = 0;
        var callee = function() {
            count += 1;
            if (count > 10) {
                callee = fast;
                return fast.apply(this, arguments);
            }
            return slow.apply(this, arguments);
        };
        return function () {
            return callee.apply(this, arguments);
        };
    },
    bytes: bytes,
    bytesFromAscii: bytesFromAscii,
    builtins: {
        Prelude: {
            sqrt: Math.sqrt,
            "+": function (x) { return x[infixlTag] + x[infixrTag]; },
            "-": function (x) { return x[infixlTag] - x[infixrTag]; },
            "*": function (x) { return x[infixlTag] * x[infixrTag]; },
            "/": function (x) { return x[infixlTag] / x[infixrTag]; },
            "^": function (x) { return Math.pow(x[infixlTag], x[infixrTag]); },
            div: function (x) { return Math.floor(x[infixlTag] / x[infixrTag]); },
            mod: function (x) {
                var modulus = x[infixrTag];
                var r = x[infixlTag] % modulus;
                if (r < 0)
                    r += modulus;
                return r;
            },
            negate: function (x) { return -x; },
            "==": function (x) { return bool(isEqual(x[infixlTag], x[infixrTag])); },
            "/=": function (x) { return bool(!isEqual(x[infixlTag], x[infixrTag])); },
            ">=": function (x) { return bool(x[infixlTag] >= x[infixrTag]); },
            ">": function (x) { return bool(x[infixlTag] > x[infixrTag]); },
            "<=": function (x) { return bool(x[infixlTag] <= x[infixrTag]); },
            "<": function (x) { return bool(x[infixlTag] < x[infixrTag]); },
        },
        Bytes: {
            length: function (x) { return x.length; },
            byteAt: function (x) { return x[objTag][x[indexTag]]; },
            slice: function (x) { return x[objTag].subarray(x[startTag], x[stopTag]); },
            unshare: function (x) { return x.slice(); },
            fromArray: function (x) { return bytes(x); },
        },
        Array: {
            length: function (x) { return x.length; },
            item: function (x) { return x[objTag][x[indexTag]]; },
        },
        Mut: {
            return: mutFunc(x => x),
            bind: function(x) {
                return function (cont) {
                    return x[infixlTag](res => x[infixrTag](res)(cont));
                };
            },
            run: function(st) { return st(x => x); },
            Array: {
                length: mutFunc(x => x.length),
                read: mutFunc(x => x[objTag][x[indexTag]]),
                write: mutFunc(x => { x[objTag][x[indexTag]] = x[valTag]; return {}; } ),
                append: mutFunc(x => { x[objTag].push(x[valTag]); return {}; } ),
                truncate: mutFunc(x => {
                    var arr = x[objTag];
                    arr.length = Math.min(arr.length, x[stopTag]);
                    return {};
                }),
                new: cont => cont([]),
                run: function(st) {
                    var result = st(x => x);
                    if (result.hasOwnProperty("cacheId")) {
                        delete result.cacheId;
                    }
                    return result;
                },
            },
            Ref: {
                new: mutFunc(x => { return {val: x}; }),
                read: mutFunc(x => x.val),
                write: mutFunc(x => { x[objTag].val = x[valTag]; return {}; }),
            },
        },
        IO: {
            file: {
                unlink: mutVoidWithError(path =>
                    require('fs').unlink.bind(null, toString(path))),
                rename: mutVoidWithError(x =>
                    require('fs').rename.bind(null, toString(x[oldPathTag]), toString(x[newPathTag]))),
                chmod: mutVoidWithError(x =>
                    require('fs').chmod.bind(null, toString(x[filePathTag]), x[modeTag])),
                link: mutVoidWithError(x =>
                    require('fs').link.bind(null, toString(x[srcPathTag]), toString(x[dstPathTag]))),
                readFile: function(path) {
                    return function(cont) {
                        require('fs').readFile(toString(path), (err, data) => {
                            if (err) throw err;
                            cont(bytes(data));
                        });
                    };
                },
                appendFile: mutVoidWithError(x =>
                    require('fs').appendFile.bind(null, toString(x[filePathTag]), Buffer.from(x[dataTag]), null)),
                writeFile: mutVoidWithError(x =>
                    require('fs').writeFile.bind(null, toString(x[filePathTag]), Buffer.from(x[dataTag])), null),
            },
            network: {
                openTcpServer: mutFunc(x => {
                    var server = require('net').Server(socket => {
                        makeOpaque(socket);
                        x[connectionHandlerTag](socket)(dataHandler =>
                            socket.on('data', data => { dataHandler(new Uint8Array(data))(x => null); } )
                        );
                    });
                    server.listen({
                        host: toString(x[hostTag]),
                        port: x[portTag],
                        exclusive: bool(x[exclusiveTag])
                    });
                    makeOpaque(server);
                    return server;
                }),
                closeTcpServer: function (server) {
                    return function (cont) {
                        server.close(cont);
                    };
                },
                socketSend: function (x) {
                    return function (cont) {
                        x[socketTag].write(Buffer.from(x[dataTag]), null, cont);
                    };
                }
            },
            database: {
                postgres: {
                    connect: function(x) {
                        return function(cont) {
                            var pg = require('pg');
                            var client = new pg.Client({
                                host: toString(x[hostTag]),
                                port: x[portTag],
                                database: toString(x[databaseTag]),
                                user: toString(x[userTag]),
                                password: toString(x[passwordTag])
                            });
                            makeOpaque(client);
                            client.connect(err => {
                                if (err) throw err;
                                cont(client);
                            });
                        };
                    },
                    query: function(x) {
                        return function(cont) {
                            x[databaseTag].query(toString(x[objTag]), (err, resJs) => {
                                if (err) {
                                    cont({tag: errorTag, data: bytesFromAscii(err.message)});
                                    return;
                                }
                                var fields = [];
                                for (var i = 0; i < resJs.fields.length; ++i) {
                                    fields.push(bytesFromAscii(resJs.fields[i].name));
                                }
                                var rows = [];
                                for (i = 0; i < resJs.rows.length; ++i) {
                                    var jsRow = resJs.rows[i];
                                    var row = [];
                                    for (var k = 0; k < resJs.fields.length; ++k) {
                                        row.push(bytesFromAscii(String(jsRow[resJs.fields[k].name])));
                                    }
                                    rows.push(row);
                                }
                                var resLamdu = {};
                                resLamdu[fieldsTag] = fields;
                                resLamdu[dataTag] = rows;
                                cont({tag: successTag, data: resLamdu});
                            });
                        };
                    }
                }
            }
        }
    }
};
