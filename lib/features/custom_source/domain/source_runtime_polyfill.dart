/// 浏览器环境 polyfill，借鉴自 phg-music 的服务器端音源执行器
/// (https://github.com/erikjamesgz/phg-music)。
///
/// 一些混淆音源（如 sixyin）会校验运行环境（window/document/navigator/
/// XMLHttpRequest/crypto.subtle 等），环境缺失时抛"加载音源脚本失败"或
/// 拒绝注册 handler。这里提供完整 DOM polyfill + 原生 sha256，让这类
/// 源在 QuickJS/JSCore 里通过自校验。
//
// ignore_for_file: prefer_interpolation_to_compose_strings
class SourceRuntimePolyfill {
  static const String sha256Js = r'''globalThis.__sha256 = function(ascii) {
  function rightRotate(value, amount) { return (value>>>amount) | (value<<(32-amount)); }
  var mathPow = Math.pow, maxWord = mathPow(2, 32), lengthProperty = 'length';
  var i, j, result = '';
  var words = [], asciiBitLength = ascii[lengthProperty]*8;
  var hash = [], k = [], primeCounter = 0;
  var isComposite = {};
  for (var candidate = 2; primeCounter < 64; candidate++) {
    if (!isComposite[candidate]) {
      for (i = 0; i < 313; i += candidate) isComposite[i] = candidate;
      hash[primeCounter] = (mathPow(candidate, .5)*maxWord)|0;
      k[primeCounter++] = (mathPow(candidate, 1/3)*maxWord)|0;
    }
  }
  ascii += '\x80';
  while (ascii[lengthProperty]%64 - 56) ascii += '\x00';
  for (i = 0; i < ascii[lengthProperty]; i++) {
    j = ascii.charCodeAt(i);
    if (j>>8) return '';
    words[i>>2] |= j << ((3-i)%4)*8;
  }
  words[words[lengthProperty]] = ((asciiBitLength/maxWord)|0);
  words[words[lengthProperty]] = (asciiBitLength);
  for (j = 0; j < words[lengthProperty];) {
    var w = words.slice(j, j += 16), oldHash = hash;
    hash = hash.slice(0, 8);
    for (i = 0; i < 64; i++) {
      var w15 = w[i-15], w2 = w[i-2];
      var a = hash[0], e = hash[4];
      var temp1 = hash[7] + (rightRotate(e, 6)^rightRotate(e, 11)^rightRotate(e, 25)) + ((e&hash[5])^((~e)&hash[6])) + k[i] + (w[i] = (i<16) ? w[i] : (w[i-16] + (rightRotate(w15, 7)^rightRotate(w15, 18)^(w15>>>3)) + w[i-7] + (rightRotate(w2, 17)^rightRotate(w2, 19)^(w2>>>10)))|0);
      var temp2 = (rightRotate(a, 2)^rightRotate(a, 13)^rightRotate(a, 22)) + ((a&hash[1])^(a&hash[2])^(hash[1]&hash[2]));
      hash = [(temp1+temp2)|0].concat(hash);
      hash[4] = (hash[4]+temp1)|0;
    }
    for (i = 0; i < 8; i++) hash[i] = (hash[i]+oldHash[i])|0;
  }
  for (i = 0; i < 8; i++) { for (j = 3; j+1; j--) { var b = (hash[i]>>(j*8))&255; result += ((b<16)?0:'') + b.toString(16); } }
  return result;
};
''';

  static const String lxNativeJs = r'''globalThis.__lx_native__ = function(key, action, data) {
  if (action === 'sha256_compute') return globalThis.__sha256(String(data));
  return '';
};
''';

  static const String domPolyfill = r'''(function() {
'use strict';
if(typeof globalThis.window==='undefined') globalThis.window=globalThis;
if(typeof globalThis.self==='undefined') globalThis.self=globalThis;
if(typeof globalThis.top==='undefined') globalThis.top=globalThis;
if(typeof globalThis.parent==='undefined') globalThis.parent=globalThis;
if(typeof globalThis.global==='undefined') globalThis.global=globalThis;
globalThis.document=globalThis.document||{owner:null,readyState:'complete',cookie:'',referrer:'',domain:'localhost',location:{href:'https://localhost/',protocol:'https:',host:'localhost'},createElement:function(tag){var el={tagName:tag.toUpperCase(),nodeName:tag.toUpperCase(),style:{},className:'',innerHTML:'',innerText:'',textContent:'',outerHTML:'',children:[],childNodes:[],firstChild:null,lastChild:null,nextSibling:null,previousSibling:null,parentNode:null,parentElement:null,ownerDocument:globalThis.document,owner:null,nodeType:1,setAttribute:function(k,v){this[k]=v},getAttribute:function(k){return this[k]||null},removeAttribute:function(k){delete this[k]},appendChild:function(c){this.children.push(c);c.parentNode=this;return c},removeChild:function(c){var i=this.children.indexOf(c);if(i>=0)this.children.splice(i,1);return c},insertBefore:function(n,r){var i=this.children.indexOf(r);if(i>=0)this.children.splice(i,0,n);else this.children.push(n);n.parentNode=this;return n},addEventListener:function(){},removeEventListener:function(){},dispatchEvent:function(){return true},getElementsByClassName:function(){return[]},getElementsByTagName:function(){return[]},querySelector:function(){return null},querySelectorAll:function(){return[]},classList:{add:function(){},remove:function(){},contains:function(){return false},toggle:function(){}}};if(tag==='canvas'){el.getContext=function(){return{fillRect:function(){},clearRect:function(){},getImageData:function(x,y,w,h){return{data:new Uint8Array(w*h*4)}},putImageData:function(){},createImageData:function(){return{data:new Uint8Array(0)}},setTransform:function(){},drawImage:function(){},save:function(){},fillText:function(){},restore:function(){},beginPath:function(){},moveTo:function(){},lineTo:function(){},closePath:function(){},stroke:function(){},translate:function(){},scale:function(){},rotate:function(){},arc:function(){},fill:function(){},measureText:function(){return{width:0}}}};el.toDataURL=function(){return'data:image/png;base64,'}}if(tag==='input'||tag==='textarea'){el.value='';el.focus=function(){};el.blur=function(){}}if(tag==='form'){el.submit=function(){}}if(tag==='script'){el.src=''}return el},getElementById:function(){return null},getElementsByTagName:function(){return[]},getElementsByClassName:function(){return[]},querySelector:function(){return null},querySelectorAll:function(){return[]},addEventListener:function(){},removeEventListener:function(){},dispatchEvent:function(){return true},createEvent:function(){return{initEvent:function(){},preventDefault:function(){},stopPropagation:function(){}}},documentElement:{nodeName:'HTML',owner:null,nodeType:9,style:{}},body:{appendChild:function(){return null},removeChild:function(){return null},owner:null,nodeType:1,style:{}},head:{appendChild:function(){return null},removeChild:function(){return null},owner:null,nodeType:1,style:{}},createTextNode:function(t){return{textContent:t,nodeType:3,owner:null,parentNode:null}},createComment:function(t){return{textContent:t,nodeType:8,owner:null}},createDocumentFragment:function(){return{children:[],appendChild:function(c){this.children.push(c);return c},owner:null,nodeType:11}},createRange:function(){return{selectNode:function(){},collapse:function(){},getBoundingClientRect:function(){return{top:0,left:0,bottom:0,right:0,width:0,height:0}}}},implementation:{hasFeature:function(){return true},createHTMLDocument:function(){return globalThis.document}}};
globalThis.navigator=globalThis.navigator||{userAgent:'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',platform:'Win32',language:'zh-CN',languages:['zh-CN','zh','en-US','en'],onLine:true,cookieEnabled:true,hardwareConcurrency:8,deviceMemory:8,maxTouchPoints:0,vendor:'Google Inc.',appName:'Netscape',appVersion:'5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',product:'Gecko',productSub:'20030107',userAgentData:{brands:[{brand:'Not_A Brand',version:'8'},{brand:'Chromium',version:'120'}],mobile:false,platform:'Windows'},connection:{effectiveType:'4g',downlink:10,rtt:50},mediaDevices:{enumerateDevices:function(){return Promise.resolve([])}},permissions:{query:function(){return Promise.resolve({state:'granted'})}},clipboard:{readText:function(){return Promise.resolve('')},writeText:function(){return Promise.resolve()}},getBattery:function(){return Promise.resolve({charging:true,chargingTime:0,dischargingTime:Infinity,level:1})},getGamepads:function(){return[]},sendBeacon:function(){return true},webkitGetUserMedia:function(){},mimeTypes:{length:0},plugins:{length:0}};
globalThis.location=globalThis.location||{href:'https://localhost/',protocol:'https:',host:'localhost',hostname:'localhost',origin:'https://localhost',port:'',pathname:'/',search:'',hash:''};
globalThis.screen=globalThis.screen||{width:1920,height:1080,colorDepth:24,pixelDepth:24,availWidth:1920,availHeight:1040,orientation:{type:'landscape-primary',angle:0}};
globalThis.history=globalThis.history||{length:1,pushState:function(){},replaceState:function(){},go:function(){},back:function(){},forward:function(){}};
globalThis.localStorage=globalThis.localStorage||{getItem:function(){return null},setItem:function(){},removeItem:function(){},clear:function(){},length:0};
globalThis.sessionStorage=globalThis.sessionStorage||{getItem:function(){return null},setItem:function(){},removeItem:function(){},clear:function(){},length:0};
if(typeof globalThis.crypto==='undefined'||!globalThis.crypto.getRandomValues){
  var _cryptoRng=function(){var _s=Date.now();return function(){_s=(_s*9301+49297)%233280;return _s/233280}};
  globalThis.crypto={getRandomValues:function(arr){if(arr instanceof Uint8Array){for(var i=0;i<arr.length;i++)arr[i]=Math.floor(Math.random()*256)}else if(arr instanceof Uint16Array){for(var i=0;i<arr.length;i++)arr[i]=Math.floor(Math.random()*65536)}else if(arr instanceof Uint32Array){for(var i=0;i<arr.length;i++)arr[i]=Math.floor(Math.random()*4294967296)}else if(Array.isArray(arr)){for(var i=0;i<arr.length;i++)arr[i]=Math.floor(Math.random()*256)}return arr},randomUUID:function(){return'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g,function(c){var r=Math.random()*16|0;return(c==='x'?r:(r&0x3|0x8)).toString(16)})},subtle:{digest:function(algo,data){return new Promise(function(resolve,reject){try{var algoName=typeof algo==='string'?algo:algo.name;var dataStr='';if(typeof data==='string'){dataStr=data}else if(data instanceof ArrayBuffer||data instanceof Uint8Array){var bytes=new Uint8Array(data);for(var i=0;i<bytes.length;i++)dataStr+=String.fromCharCode(bytes[i])}console.log('[Polyfill] crypto.subtle.digest called, algo='+algoName+', dataLen='+dataStr.length);var hexResult=__lx_native__('cf_worker_key','sha256_compute',dataStr);console.log('[Polyfill] crypto.subtle.digest result, hexLen='+(hexResult?hexResult.length:0)+', hexPrefix='+(hexResult?hexResult.substring(0,16):'null'));var ab=new ArrayBuffer(hexResult.length/2);var view=new Uint8Array(ab);for(var i=0;i<hexResult.length;i+=2)view[i/2]=parseInt(hexResult.substr(i,2),16);resolve(ab)}catch(e){console.log('[Polyfill] crypto.subtle.digest ERROR: '+e.message);reject(e)}})},importKey:function(){return Promise.resolve({})},exportKey:function(){return Promise.resolve(new ArrayBuffer(0))},encrypt:function(){return Promise.resolve(new ArrayBuffer(0))},decrypt:function(){return Promise.resolve(new ArrayBuffer(0))},sign:function(){return Promise.resolve(new ArrayBuffer(0))},verify:function(){return Promise.resolve(false)},generateKey:function(){return Promise.resolve({})},deriveBits:function(){return Promise.resolve(new ArrayBuffer(0))},deriveKey:function(){return Promise.resolve({})}}};
}
if(typeof globalThis.performance==='undefined'){
  var _perfStart=Date.now();
  globalThis.performance={now:function(){return Date.now()-_perfStart},mark:function(){},measure:function(){},getEntries:function(){return[]},getEntriesByName:function(){return[]},getEntriesByType:function(){return[]},clearMarks:function(){},clearMeasures:function(){},timeOrigin:_perfStart};
}
if(typeof TextEncoder==='undefined'){globalThis.TextEncoder=function(){this.encode=function(s){var bytes=[];for(var i=0;i<s.length;i++){var c=s.charCodeAt(i);if(c<128)bytes.push(c);else if(c<2048){bytes.push((c>>6)|192);bytes.push((c&63)|128)}else{bytes.push((c>>12)|224);bytes.push(((c>>6)&63)|128);bytes.push((c&63)|128)}}return new Uint8Array(bytes)}}}
if(typeof TextDecoder==='undefined'){globalThis.TextDecoder=function(){this.decode=function(arr){var s='';for(var i=0;i<arr.length;i++)s+=String.fromCharCode(arr[i]);return s}}}
if(typeof btoa==='undefined'){globalThis.btoa=function(str){var chars='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';var output='';for(var i=0;i<str.length;i+=3){var b1=str.charCodeAt(i);var b2=i+1<str.length?str.charCodeAt(i+1):0;var b3=i+2<str.length?str.charCodeAt(i+2):0;output+=chars.charAt(b1>>2)+chars.charAt(((b1&3)<<4)|(b2>>4))+(i+1<str.length?chars.charAt(((b2&15)<<2)|(b3>>6)):'=')+(i+2<str.length?chars.charAt(b3&63):'=')}return output}}
if(typeof atob==='undefined'){globalThis.atob=function(b64){var chars='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';var output='';var i=0;b64=b64.replace(/[^A-Za-z0-9\\+\\/\\=]/g,'');while(i<b64.length){var e1=chars.indexOf(b64.charAt(i++));var e2=chars.indexOf(b64.charAt(i++));var e3=chars.indexOf(b64.charAt(i++));var e4=chars.indexOf(b64.charAt(i++));output+=String.fromCharCode((e1<<2)|(e2>>4))+(e3!==64?String.fromCharCode(((e2&15)<<4)|(e3>>2)):'')+(e4!==64?String.fromCharCode(((e3&3)<<6)|e4):'')}return output}}
if(typeof globalThis.XMLHttpRequest==='undefined'){
  globalThis.XMLHttpRequest=function(){this.readyState=0;this.status=0;this.statusText='';this.responseText='';this.responseXML=null;this.response=null;this.responseType='';this.withCredentials=false;this.timeout=0;this.onreadystatechange=null;this.onload=null;this.onerror=null;this.onabort=null;this.ontimeout=null;this.onprogress=null;this.upload={addEventListener:function(){}};this._headers={};this._method='GET';this._url='';this._async=true;this._aborted=false};
  globalThis.XMLHttpRequest.prototype.open=function(method,url,async){this._method=method;this._url=url;this._async=async!==false;this.readyState=1};
  globalThis.XMLHttpRequest.prototype.send=function(body){var self=this;this.readyState=2;if(this._url){globalThis.lx.request(this._url,{method:this._method,body:body,headers:this._headers},function(err,resp,respBody){if(self._aborted)return;if(err){self.readyState=4;self.status=0;if(self.onerror)self.onerror(err)}else{self.readyState=4;self.status=resp?resp.statusCode:0;self.statusText=resp?resp.statusMessage:'';self.responseText=typeof respBody==='string'?respBody:(respBody?JSON.stringify(respBody):'');self.response=self.responseText;if(self.onload)self.onload()}if(self.onreadystatechange)self.onreadystatechange()})}else{this.readyState=4;this.status=0;if(this.onerror)this.onerror(new Error('No URL'))}};
  globalThis.XMLHttpRequest.prototype.abort=function(){this._aborted=true;this.readyState=4;if(this.onabort)this.onabort()};
  globalThis.XMLHttpRequest.prototype.setRequestHeader=function(k,v){this._headers[k]=v};
  globalThis.XMLHttpRequest.prototype.getResponseHeader=function(){return null};
  globalThis.XMLHttpRequest.prototype.getAllResponseHeaders=function(){return''};
  globalThis.XMLHttpRequest.prototype.addEventListener=function(type,fn){this['on'+type]=fn};
  globalThis.XMLHttpRequest.prototype.removeEventListener=function(){};
  globalThis.XMLHttpRequest.prototype.overrideMimeType=function(){};
}
if(typeof globalThis.URL==='undefined'){
  globalThis.URL=function(url,base){this.href=url;this.protocol='';this.host='';this.hostname='';this.port='';this.pathname='';this.search='';this.hash='';this.origin='';try{var m=url.match(new RegExp('^(https?:)\\\\/\\\\/([^\\\\/:]+)(:\\\\d+)?([^?#]*)(\\\\?[^#]*)?(#.*)?$'));if(m){this.protocol=m[1];this.hostname=m[2];this.port=m[3]?m[3].slice(1):'';this.host=this.hostname+(this.port?':'+this.port:'');this.pathname=m[4]||'/';this.search=m[5]||'';this.hash=m[6]||'';this.origin=this.protocol+'//'+this.host}}catch(e){}};
  globalThis.URL.createObjectURL=function(){return'blob:null'};
  globalThis.URL.revokeObjectURL=function(){};
}
if(typeof globalThis.URLSearchParams==='undefined'){
  globalThis.URLSearchParams=function(init){this._params=[];if(typeof init==='string'){if(init.charAt(0)==='?')init=init.slice(1);init.split('&').forEach(function(pair){var idx=pair.indexOf('=');if(idx>=0)this._params.push([decodeURIComponent(pair.slice(0,idx)),decodeURIComponent(pair.slice(idx+1))]);else if(pair)this._params.push([decodeURIComponent(pair),''])}.bind(this))}};
  globalThis.URLSearchParams.prototype.get=function(name){for(var i=0;i<this._params.length;i++){if(this._params[i][0]===name)return this._params[i][1]}return null};
  globalThis.URLSearchParams.prototype.set=function(name,value){var found=false;for(var i=0;i<this._params.length;i++){if(this._params[i][0]===name){this._params[i][1]=value;found=true;break}}if(!found)this._params.push([name,value])};
  globalThis.URLSearchParams.prototype.has=function(name){for(var i=0;i<this._params.length;i++){if(this._params[i][0]===name)return true}return false};
  globalThis.URLSearchParams.prototype.append=function(name,value){this._params.push([name,value])};
  globalThis.URLSearchParams.prototype.toString=function(){return this._params.map(function(p){return encodeURIComponent(p[0])+'='+encodeURIComponent(p[1])}).join('&')};
  globalThis.URLSearchParams.prototype.forEach=function(fn){this._params.forEach(function(p){fn(p[1],p[0])})};
}
if(typeof globalThis.Headers==='undefined'){
  globalThis.Headers=function(init){this._map={};if(init&&typeof init==='object'){if(init instanceof Array){init.forEach(function(pair){this._map[pair[0].toLowerCase()]=pair[1]}.bind(this))}else{Object.keys(init).forEach(function(k){this._map[k.toLowerCase()]=init[k]}.bind(this))}}};
  globalThis.Headers.prototype.get=function(name){return this._map[name.toLowerCase()]||null};
  globalThis.Headers.prototype.set=function(name,value){this._map[name.toLowerCase()]=value};
  globalThis.Headers.prototype.has=function(name){return name.toLowerCase()in this._map};
  globalThis.Headers.prototype.delete=function(name){delete this._map[name.toLowerCase()]};
  globalThis.Headers.prototype.append=function(name,value){this._map[name.toLowerCase()]=value};
  globalThis.Headers.prototype.forEach=function(fn){var self=this;Object.keys(this._map).forEach(function(k){fn(self._map[k],k)})};
}
if(typeof globalThis.FormData==='undefined'){
  globalThis.FormData=function(){this._data=[]};
  globalThis.FormData.prototype.append=function(name,value){this._data.push([name,value])};
  globalThis.FormData.prototype.get=function(name){for(var i=0;i<this._data.length;i++){if(this._data[i][0]===name)return this._data[i][1]}return null};
  globalThis.FormData.prototype.has=function(name){for(var i=0;i<this._data.length;i++){if(this._data[i][0]===name)return true}return false};
}
if(typeof globalThis.Blob==='undefined'){
  globalThis.Blob=function(parts,options){this.size=0;this.type=(options&&options.type)||'';var data=[];if(parts){parts.forEach(function(p){if(typeof p==='string'){for(var i=0;i<p.length;i++)data.push(p.charCodeAt(i))}else if(p instanceof Uint8Array||Array.isArray(p)){data=data.concat(Array.from(p))}})}this.size=data.length;this._data=data;this.arrayBuffer=function(){return Promise.resolve(new Uint8Array(data).buffer)};this.text=function(){var s='';for(var i=0;i<data.length;i++)s+=String.fromCharCode(data[i]);return Promise.resolve(s)};this.slice=function(start,end){return new Blob([new Uint8Array(data.slice(start,end))],{type:this.type})}};
}
if(typeof globalThis.File==='undefined'){
  globalThis.File=function(parts,name,options){Blob.call(this,parts,options);this.name=name;this.lastModified=Date.now()};
  globalThis.File.prototype=Object.create(Blob.prototype);
}
if(typeof globalThis.FileReader==='undefined'){
  globalThis.FileReader=function(){this.readyState=0;this.result=null;this.onload=null;this.onerror=null;this.readAsText=function(blob){var self=this;this.readyState=2;this.result=blob.text?blob.text():'';if(this.onload)setTimeout(function(){self.onload({target:self})},0)};this.readAsArrayBuffer=function(blob){var self=this;this.readyState=2;this.result=blob.arrayBuffer?blob.arrayBuffer():new ArrayBuffer(0);if(this.onload)setTimeout(function(){self.onload({target:self})},0)};this.readAsDataURL=function(blob){var self=this;this.readyState=2;this.result='data:'+blob.type+';base64,'+btoa(String.fromCharCode.apply(null,blob._data||[]));if(this.onload)setTimeout(function(){self.onload({target:self})},0)}};
}
if(typeof globalThis.AbortController==='undefined'){
  globalThis.AbortController=function(){this.signal={aborted:false,_listeners:[],addEventListener:function(type,fn){this._listeners.push(fn)},removeEventListener:function(){},throwIfAborted:function(){if(this.aborted)throw new Error('AbortError')}};this.abort=function(){this.signal.aborted=true;this.signal._listeners.forEach(function(fn){fn()})}};
  globalThis.AbortSignal=function(){this.aborted=false;this._listeners=[];this.addEventListener=function(type,fn){this._listeners.push(fn)};this.removeEventListener=function(){};this.throwIfAborted=function(){if(this.aborted)throw new Error('AbortError')}};
  globalThis.AbortSignal.abort=function(){var s=new AbortSignal();s.aborted=true;return s};
  globalThis.AbortSignal.timeout=function(ms){var s=new AbortSignal();setTimeout(function(){s.aborted=true;s._listeners.forEach(function(fn){fn()})},ms);return s};
}
if(typeof globalThis.Event==='undefined'){
  globalThis.Event=function(type,opts){this.type=type;this.bubbles=(opts&&opts.bubbles)||false;this.cancelable=(opts&&opts.cancelable)||false;this.defaultPrevented=false;this.target=null;this.currentTarget=null;this.timeStamp=Date.now()};
  globalThis.Event.prototype.preventDefault=function(){this.defaultPrevented=true};
  globalThis.Event.prototype.stopPropagation=function(){};
  globalThis.Event.prototype.stopImmediatePropagation=function(){};
}
if(typeof globalThis.CustomEvent==='undefined'){
  globalThis.CustomEvent=function(type,opts){Event.call(this,type,opts);this.detail=(opts&&opts.detail)||null};
  globalThis.CustomEvent.prototype=Object.create(Event.prototype);
}
if(typeof globalThis.EventTarget==='undefined'){
  globalThis.EventTarget=function(){this._listeners={}};
  globalThis.EventTarget.prototype.addEventListener=function(type,fn){if(!this._listeners[type])this._listeners[type]=[];this._listeners[type].push(fn)};
  globalThis.EventTarget.prototype.removeEventListener=function(type,fn){if(this._listeners[type]){var i=this._listeners[type].indexOf(fn);if(i>=0)this._listeners[type].splice(i,1)}};
  globalThis.EventTarget.prototype.dispatchEvent=function(event){event.target=this;event.currentTarget=this;if(this._listeners[event.type]){this._listeners[event.type].forEach(function(fn){fn(event)})}return!event.defaultPrevented};
}
if(typeof globalThis.DOMParser==='undefined'){
  globalThis.DOMParser=function(){};
  globalThis.DOMParser.prototype.parseFromString=function(str,type){return globalThis.document};
}
if(typeof globalThis.MutationObserver==='undefined'){
  globalThis.MutationObserver=function(cb){this._cb=cb};
  globalThis.MutationObserver.prototype.observe=function(){};
  globalThis.MutationObserver.prototype.disconnect=function(){};
  globalThis.MutationObserver.prototype.takeRecords=function(){return[]};
}
if(typeof globalThis.IntersectionObserver==='undefined'){
  globalThis.IntersectionObserver=function(cb){this._cb=cb};
  globalThis.IntersectionObserver.prototype.observe=function(){};
  globalThis.IntersectionObserver.prototype.disconnect=function(){};
  globalThis.IntersectionObserver.prototype.unobserve=function(){};
}
if(typeof globalThis.ResizeObserver==='undefined'){
  globalThis.ResizeObserver=function(cb){this._cb=cb};
  globalThis.ResizeObserver.prototype.observe=function(){};
  globalThis.ResizeObserver.prototype.disconnect=function(){};
  globalThis.ResizeObserver.prototype.unobserve=function(){};
}
if(typeof globalThis.requestAnimationFrame==='undefined'){
  globalThis.requestAnimationFrame=function(cb){return globalThis.setTimeout(cb,16)};
  globalThis.requestAnimationFrame=function(cb){return globalThis.setTimeout(cb,16)};
  globalThis.cancelAnimationFrame=function(id){globalThis.clearTimeout(id)};
}
if(typeof globalThis.queueMicrotask==='undefined'){
  globalThis.queueMicrotask=function(cb){Promise.resolve().then(cb)};
}
if(typeof globalThis.structuredClone==='undefined'){
  globalThis.structuredClone=function(obj){return JSON.parse(JSON.stringify(obj))};
}
if(typeof globalThis.MessageChannel==='undefined'){
  globalThis.MessageChannel=function(){this.port1={postMessage:function(){},onmessage:null,close:function(){}};this.port2={postMessage:function(){},onmessage:null,close:function(){}}};
}
if(typeof globalThis.Worker==='undefined'){
  globalThis.Worker=function(url){this.onmessage=null;this.onerror=null;this.postMessage=function(){};this.terminate=function(){};this.addEventListener=function(){}};
}
if(typeof globalThis.Image==='undefined'){
  globalThis.Image=function(){this.src='';this.onload=null;this.onerror=null;this.width=0;this.height=0;this.naturalWidth=0;this.naturalHeight=0};
}
if(typeof globalThis.Audio==='undefined'){
  globalThis.Audio=function(){this.src='';this.onload=null;this.onerror=null};
}
globalThis.require=function(moduleName){
  console.log('[Polyfill] require() called: '+moduleName);
  if(moduleName==='crypto'){
    return{
      createCipheriv:function(){return{update:function(){return this},final:function(){return''}}},
      createDecipheriv:function(){return{update:function(){return this},final:function(){return''}}},
      randomBytes:function(s){var r=[];for(var i=0;i<s;i++)r.push(Math.floor(Math.random()*256));return r},
      createHash:function(algo){
        var data='';
        console.log('[Polyfill] require("crypto").createHash called, algo='+algo);
        return{
          update:function(d,enc){
            if(typeof d==='string'){
              if(enc==='base64'){var b=atob(d);data+=b}
              else if(enc==='hex'){var b='';for(var i=0;i<d.length;i+=2)b+=String.fromCharCode(parseInt(d.substr(i,2),16));data+=b}
              else{data+=d}
            }else if(d instanceof Uint8Array||Array.isArray(d)){
              for(var i=0;i<d.length;i++)data+=String.fromCharCode(d[i])
            }
            return this
          },
          digest:function(enc){
            console.log('[Polyfill] createHash.digest called, algo='+algo+', dataLen='+data.length+', enc='+enc+', dataPreview='+JSON.stringify(data.substring(0,100)));
            var h;
            if(algo==='md5'){h=__lx_native__('cf_worker_key','md5_compute',data)}
            else{h=__lx_native__('cf_worker_key','sha256_compute',data)}
            console.log('[Polyfill] createHash.digest result, hexLen='+(h?h.length:0)+', hexPrefix='+(h?h.substring(0,16):'null'));
            if(enc==='hex')return h;
            if(enc==='base64'){var bytes=[];for(var i=0;i<h.length;i+=2)bytes.push(parseInt(h.substr(i,2),16));return btoa(String.fromCharCode.apply(null,bytes))}
            var bytes=[];for(var i=0;i<h.length;i+=2)bytes.push(parseInt(h.substr(i,2),16));return new Uint8Array(bytes)
          }
        }
      },
      publicEncrypt:function(){return''},
      constants:{RSA_NO_PADDING:4,OAEPWithSHA1AndMGF1Padding:''}
    }
  }
  if(moduleName==='buffer'){
    return{
      Buffer:{
        from:function(i,e){
          if(typeof i==='string'){
            if(e==='base64'){var b=atob(i);var r=new Uint8Array(b.length);for(var j=0;j<b.length;j++)r[j]=b.charCodeAt(j);return r}
            if(e==='hex'){var r=new Uint8Array(i.length/2);for(var j=0;j<i.length;j+=2)r[j/2]=parseInt(i.substr(j,2),16);return r}
            var r=new Uint8Array(i.length);for(var j=0;j<r.length;j++)r[j]=i.charCodeAt(j);return r
          }
          if(Array.isArray(i))return new Uint8Array(i);
          if(i instanceof Uint8Array)return i;
          throw new Error('Unsupported input')
        },
        alloc:function(s){return new Uint8Array(s)}
      }
    }
  }
  if(moduleName==='zlib')return{inflate:function(b){return b},deflate:function(b){return b}};
  if(moduleName==='http'||moduleName==='https'||moduleName==='net'||moduleName==='tls'||moduleName==='fs'||moduleName==='path'||moduleName==='os'||moduleName==='stream'||moduleName==='events'||moduleName==='util'||moduleName==='url'||moduleName==='querystring'||moduleName==='child_process'){
    var _emptyMod={on:function(){return _emptyMod},once:function(){return _emptyMod},emit:function(){return true},pipe:function(){return _emptyMod},write:function(){return true},end:function(){return _emptyMod},destroy:function(){return _emptyMod},read:function(){return null},close:function(){},createServer:function(){return _emptyMod},connect:function(){return _emptyMod},listen:function(){return _emptyMod}};
    return _emptyMod;
  }
  console.warn('[Polyfill] require("'+moduleName+'") - returning empty object');
  return{}
};
if(typeof globalThis.Buffer==='undefined'){
  globalThis.Buffer={
    from:function(input,encoding){
      if(typeof input==='string'){
        if(encoding==='base64'){var b=atob(input);var r=new Uint8Array(b.length);for(var i=0;i<b.length;i++)r[i]=b.charCodeAt(i);return r}
        if(encoding==='hex'){var r=new Uint8Array(input.length/2);for(var i=0;i<input.length;i+=2)r[i/2]=parseInt(input.substr(i,2),16);return r}
        if(encoding==='binary'){var r=new Uint8Array(input.length);for(var i=0;i<input.length;i++)r[i]=input.charCodeAt(i);return r}
        var r=new Uint8Array(input.length);for(var i=0;i<input.length;i++)r[i]=input.charCodeAt(i);return r
      }
      if(Array.isArray(input))return new Uint8Array(input);
      if(input instanceof Uint8Array)return input;
      throw new Error('Unsupported Buffer.from input')
    },
    alloc:function(size){return new Uint8Array(size)},
    concat:function(list){var len=0;for(var i=0;i<list.length;i++)len+=list[i].length;var r=new Uint8Array(len);var off=0;for(var i=0;i<list.length;i++){r.set(list[i],off);off+=list[i].length}return r}
  }
}
if(typeof globalThis.process==='undefined'){globalThis.process={env:{},version:'v18.17.0',versions:{node:'18.17.0',v8:'10.2.154.26'},platform:'linux',arch:'x64',pid:1,ppid:0,title:'node',argv:['node'],execPath:'/usr/local/bin/node',cwd:function(){return'/'},nextTick:function(fn){Promise.resolve().then(fn)},emitWarning:function(){},binding:function(){return{}},hrtime:function(){var t=Date.now()*1e6;return[t/1e9|0,t%1e9]}}}

if(typeof globalThis.pako==='undefined'){globalThis.pako={inflate:function(d){return d},inflateRaw:function(d){return d},deflate:function(d){return d},gzip:function(d){return d},ungzip:function(d){return d}}}
if(typeof globalThis.fetch==='undefined'){
  globalThis.fetch=function(url,options){
    options=options||{};
    return new Promise(function(resolve,reject){
      var method=(options.method||'GET').toUpperCase();
      var reqHeaders={};
      if(options.headers){
        if(options.headers instanceof Map){options.headers.forEach(function(v,k){reqHeaders[k]=v})}
        else if(typeof options.headers==='object'){reqHeaders=options.headers}
      }
      if(method==='GET'&&reqHeaders['Content-Type'])delete reqHeaders['Content-Type'];
      var lxReqOpts={method:method,headers:reqHeaders,body:options.body||null,form:options.form||null,formData:options.formData||null,binary:options.binary||null};
      globalThis.lx.request(url,lxReqOpts,function(err,resp,body){
        if(err){reject(new Error('fetch error: '+(err.message||String(err))));return}
        var bodyStr='';
        if(typeof body==='string')bodyStr=body;
        else if(body&&typeof body==='object'){try{bodyStr=JSON.stringify(body)}catch(e){bodyStr=String(body)}}
        else bodyStr=body?String(body):'';
        var respHeaders=new Map();
        if(resp&&resp.headers){try{Object.keys(resp.headers).forEach(function(k){respHeaders.set(k,resp.headers[k])})}catch(e){}}
        resolve({
          ok:resp&&resp.statusCode>=200&&resp.statusCode<300,
          status:resp?resp.statusCode:0,
          statusText:resp?(resp.statusMessage||''):'',
          headers:respHeaders,
          url:url,
          text:function(){return Promise.resolve(bodyStr)},
          json:function(){return Promise.resolve(JSON.parse(bodyStr))},
          arrayBuffer:function(){var bytes=new Uint8Array(bodyStr.length);for(var i=0;i<bodyStr.length;i++)bytes[i]=bodyStr.charCodeAt(i);return Promise.resolve(bytes.buffer)}
        })
      })
    })
  }
}
if(typeof globalThis.Proxy==='undefined'){
  globalThis.Proxy=function(target,handler){
    if(!handler)return target;
    if(typeof target==='function'){
      var fn=function(){
        var args=Array.prototype.slice.call(arguments);
        if(handler.apply){try{return handler.apply(target,this,args)}catch(e){return target.apply(this,args)}}
        return target.apply(this,args);
      };
      fn.__target=target;
      fn.__handler=handler;
      for(var k in target){if(target.hasOwnProperty(k)){(function(key){Object.defineProperty(fn,key,{get:function(){if(handler.get)try{return handler.get(target,key,fn)}catch(e){return target[key]}return target[key]},set:function(v){if(handler.set)try{handler.set(target,key,v,fn)}catch(e){target[key]=v}target[key]=v},configurable:true,enumerable:true})})(k)}}
      return fn;
    }
    if(typeof target==='object'&&target!==null){
      var result={};
      var keys=Object.getOwnPropertyNames(target);
      for(var i=0;i<keys.length;i++){(function(key){Object.defineProperty(result,key,{get:function(){if(handler.get)try{return handler.get(target,key,result)}catch(e){return target[key]}return target[key]},set:function(v){if(handler.set)try{handler.set(target,key,v,result)}catch(e){target[key]=v}target[key]=v},configurable:true,enumerable:true})})(keys[i])}
      return result;
    }
    return target;
  };
  globalThis.Proxy.revocable=function(target,handler){return{proxy:new Proxy(target,handler),revoke:function(){}}};
}
if(typeof globalThis.Reflect==='undefined'){
  globalThis.Reflect={apply:function(target,thisArg,args){return target.apply(thisArg,args)},construct:function(target,args){return new(Function.prototype.bind.apply(target,[null].concat(args)))},get:function(target,prop){return target[prop]},set:function(target,prop,value){target[prop]=value;return true},has:function(target,prop){return prop in target},deleteProperty:function(target,prop){delete target[prop];return true},ownKeys:function(target){return Object.keys(target)},getOwnPropertyDescriptor:function(target,prop){return Object.getOwnPropertyDescriptor(target,prop)},defineProperty:function(target,prop,desc){Object.defineProperty(target,prop,desc);return true},getPrototypeOf:function(target){return Object.getPrototypeOf(target)},setPrototypeOf:function(target,proto){Object.setPrototypeOf(target,proto);return true},isExtensible:function(target){return Object.isExtensible(target)},preventExtensions:function(target){Object.preventExtensions(target);return true}};
}
var _origFnToString=Function.prototype.toString;
var _nativeFnRegistry=[];
var _makeNative=function(name,fn){try{_nativeFnRegistry.push([fn,name])}catch(e){}return fn};
var _nativeObjToString=function(name,obj){if(!obj)return obj;if(typeof obj==='function'){try{_nativeFnRegistry.push([obj,name])}catch(e){}}else if(typeof obj==='object'&&obj!==null){Object.keys(obj).forEach(function(k){if(typeof obj[k]==='function'){try{_nativeFnRegistry.push([obj[k],k])}catch(e){}}})}return obj};
Function.prototype.toString=function(){
  try{for(var i=0;i<_nativeFnRegistry.length;i++){if(_nativeFnRegistry[i][0]===this)return'function '+_nativeFnRegistry[i][1]+'() { [native code] }'}}catch(e){}
  try{return _origFnToString.call(this)}catch(e){return'function () { [native code] }'}
};
if(globalThis.fetch)globalThis.fetch=_makeNative('fetch',globalThis.fetch);
if(globalThis.XMLHttpRequest)_nativeObjToString('XMLHttpRequest',globalThis.XMLHttpRequest);
if(globalThis.crypto)_nativeObjToString('crypto',globalThis.crypto);
if(globalThis.TextEncoder)globalThis.TextEncoder=_makeNative('TextEncoder',globalThis.TextEncoder);
if(globalThis.TextDecoder)globalThis.TextDecoder=_makeNative('TextDecoder',globalThis.TextDecoder);
if(globalThis.btoa)globalThis.btoa=_makeNative('btoa',globalThis.btoa);
if(globalThis.atob)globalThis.atob=_makeNative('atob',globalThis.atob);
if(globalThis.URL)globalThis.URL=_makeNative('URL',globalThis.URL);
if(globalThis.URLSearchParams)globalThis.URLSearchParams=_makeNative('URLSearchParams',globalThis.URLSearchParams);
if(globalThis.Headers)globalThis.Headers=_makeNative('Headers',globalThis.Headers);
if(globalThis.FormData)globalThis.FormData=_makeNative('FormData',globalThis.FormData);
if(globalThis.Blob)globalThis.Blob=_makeNative('Blob',globalThis.Blob);
if(globalThis.File)globalThis.File=_makeNative('File',globalThis.File);
if(globalThis.FileReader)globalThis.FileReader=_makeNative('FileReader',globalThis.FileReader);
if(globalThis.AbortController)globalThis.AbortController=_makeNative('AbortController',globalThis.AbortController);
if(globalThis.Event)globalThis.Event=_makeNative('Event',globalThis.Event);
if(globalThis.CustomEvent)globalThis.CustomEvent=_makeNative('CustomEvent',globalThis.CustomEvent);
if(globalThis.EventTarget)globalThis.EventTarget=_makeNative('EventTarget',globalThis.EventTarget);
if(globalThis.DOMParser)globalThis.DOMParser=_makeNative('DOMParser',globalThis.DOMParser);
if(globalThis.MutationObserver)globalThis.MutationObserver=_makeNative('MutationObserver',globalThis.MutationObserver);
if(globalThis.requestAnimationFrame)globalThis.requestAnimationFrame=_makeNative('requestAnimationFrame',globalThis.requestAnimationFrame);
if(globalThis.cancelAnimationFrame)globalThis.cancelAnimationFrame=_makeNative('cancelAnimationFrame',globalThis.cancelAnimationFrame);
if(globalThis.queueMicrotask)globalThis.queueMicrotask=_makeNative('queueMicrotask',globalThis.queueMicrotask);
if(globalThis.structuredClone)globalThis.structuredClone=_makeNative('structuredClone',globalThis.structuredClone);
if(globalThis.performance)_nativeObjToString('performance',globalThis.performance);
if(globalThis.navigator)_nativeObjToString('navigator',globalThis.navigator);
if(globalThis.document)_nativeObjToString('document',globalThis.document);
if(globalThis.history)_nativeObjToString('history',globalThis.history);
if(globalThis.localStorage)_nativeObjToString('localStorage',globalThis.localStorage);
if(globalThis.sessionStorage)_nativeObjToString('sessionStorage',globalThis.sessionStorage);
if(globalThis.screen)_nativeObjToString('screen',globalThis.screen);
if(globalThis.location)_nativeObjToString('location',globalThis.location);
if(globalThis.require)globalThis.require=_makeNative('require',globalThis.require);
if(globalThis.Buffer)_nativeObjToString('Buffer',globalThis.Buffer);
if(globalThis.process)_nativeObjToString('process',globalThis.process);
if(globalThis.pako)_nativeObjToString('pako',globalThis.pako);
(function() {
  var _origBind = Function.prototype.bind;
  Function.prototype.bind = function() {
    if (this === globalThis || this === window || this === self) {
      var actionArg = null;
      for (var i = 0; i < arguments.length; i++) {
        if (typeof arguments[i] === 'string' && arguments[i].indexOf('Handle Action') === 0) {
          actionArg = arguments[i];
          break;
        }
      }
      console.log('[BIND-FIX] bind called on globalThis, actionArg=' + actionArg);
      if (actionArg) {
        var actionMatch = actionArg.match(/Handle Action\\((\\w+)\\)/);
        if (actionMatch) {
          var actionName = actionMatch[1];
          var handlerMap = {
            'musicUrl': 'handleGetMusicUrl',
            'musicPic': 'handleGetMusicPic',
            'musicLyric': 'handleGetMusicLyric'
          };
          var handlerName = handlerMap[actionName];
          if (handlerName && typeof globalThis[handlerName] === 'function') {
            console.log('[BIND-FIX] Redirecting to ' + handlerName);
            return _origBind.apply(globalThis[handlerName], arguments);
          }
        }
      }
      console.log('[BIND-FIX] No handler found for actionArg=' + actionArg + ', returning identity bind');
      var self = this;
      return function() { return self; };
    }
    return _origBind.apply(this, arguments);
  };
})();
console.log('Polyfill setup complete.');
})()''';

  static const String cryptoSubtleJs = r'''if (globalThis.crypto && !globalThis.crypto.subtle) {
  globalThis.crypto.subtle = {
    digest: function(algo, data) {
      return new Promise(function(resolve, reject) {
        try {
          var dataStr = '';
          if (typeof data === 'string') { dataStr = data; }
          else if (data instanceof ArrayBuffer || data instanceof Uint8Array) {
            var bytes = new Uint8Array(data);
            for (var i = 0; i < bytes.length; i++) dataStr += String.fromCharCode(bytes[i]);
          }
          var hex = globalThis.__lx_native__('', 'sha256_compute', dataStr);
          var ab = new ArrayBuffer(hex.length / 2);
          var view = new Uint8Array(ab);
          for (var i = 0; i < hex.length; i += 2) view[i/2] = parseInt(hex.substr(i, 2), 16);
          resolve(ab);
        } catch (e) { reject(e); }
      });
    },
    importKey: function(){ return Promise.resolve({}); },
    encrypt: function(){ return Promise.resolve(new ArrayBuffer(0)); },
    decrypt: function(){ return Promise.resolve(new ArrayBuffer(0)); },
    sign: function(){ return Promise.resolve(new ArrayBuffer(0)); },
    verify: function(){ return Promise.resolve(false); },
    generateKey: function(){ return Promise.resolve({}); },
    deriveBits: function(){ return Promise.resolve(new ArrayBuffer(0)); }
  };
}
''';

  static String js() {
    return sha256Js +
        '\n' +
        lxNativeJs +
        '\n' +
        cryptoSubtleJs +
        '\n' +
        domPolyfill;
  }
}
