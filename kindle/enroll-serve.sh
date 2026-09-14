#!/bin/sh
# enroll-serve.sh -- attended SSH enrollment over HTTP. One copy per connection
# (run by tcpsvd). The requester generates its OWN keypair -- in the browser
# (Generate button) or with ssh-keygen -- and sends only the PUBLIC key plus a
# name. The owner approves it on the Kindle after checking the fingerprint. The
# menu is the only thing that writes authorized_keys, and only after a y.
#
# Nothing secret ever crosses the wire: the private key stays with the requester.
# That is deliberate -- the page is plain HTTP, and the device's openssl (1.0.2)
# has no pbkdf2, so we never rely on encrypting a secret in transit.
#
#   browser:  open  http://<kindle>:<port>/   -> Generate (or paste) -> Request
#   terminal: ssh-keygen -t ed25519 -f kfx_key -N "" -C laptop
#             curl -s --data-urlencode 'name=laptop' \
#                  --data-urlencode "key=$(cat kfx_key.pub)" \
#                  http://<kindle>:<port>/enroll
#             ssh -i kfx_key -p 2222 kfx@<kindle>
#
# Spool (shared with the menu, default /tmp/kfx-enroll):
#   pending/<id>   name/ip/key, written here, read by the menu
#   decision/<id>  "approve" or "deny", written by the menu
ENROLL_DIR=${ENROLL_DIR:-/tmp/kfx-enroll}
ENROLL_WAIT=${ENROLL_WAIT:-240}
LIBDIR=$(dirname "$0")
mkdir -p "$ENROLL_DIR/pending" "$ENROLL_DIR/decision" 2>/dev/null

send() {   # $1 = status line, $2 = content-type; body follows on stdin
    printf '%s\r\n' "$1"
    printf 'Content-Type: %s\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n' "$2"
    cat
}

form_page() {
    send "HTTP/1.0 200 OK" "text/html; charset=utf-8" <<'HTML'
<!doctype html><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>shelfback -- enroll an SSH key</title>
<style>
 body{font:16px/1.5 system-ui,sans-serif;max-width:40rem;margin:2.5rem auto;padding:0 1rem;color:#222}
 h1{font-size:1.3rem} label{font-weight:600;display:block;margin:.8rem 0 .2rem}
 input,textarea{font:inherit;width:100%;box-sizing:border-box;padding:.5rem}
 textarea{height:5rem;font-family:ui-monospace,monospace;font-size:.85rem}
 button{font:inherit;padding:.5rem 1rem;cursor:pointer;margin:.3rem .3rem 0 0}
 pre,code{background:#f4f4f4} pre{padding:.8rem;overflow:auto;white-space:pre-wrap;word-break:break-all}
 code{padding:.1rem .3rem} .muted{color:#666;font-size:.9rem} .hidden{display:none}
 .fp{font-family:ui-monospace,monospace;font-size:.85rem;background:#eef;padding:.5rem;word-break:break-all}
</style>
<h1>Enroll an SSH key</h1>
<p class=muted>Your computer makes its own key. Only the <b>public</b> half is sent
to the Kindle -- the private half never leaves this page. The person at the Kindle
checks the fingerprint and approves.</p>

<label for=name>A name for this computer</label>
<input id=name placeholder="e.g. work laptop" autofocus>

<label for=key>Public key</label>
<textarea id=key placeholder="ssh-ed25519 AAAA... -- click Generate, or paste your own"></textarea>
<button id=gen>Generate a key in this browser</button>
<span id=genmsg class=muted></span>

<div id=dl class=hidden>
 <p><b>Save your private key now</b> -- it is shown once and is not stored anywhere:
    <a id=dllink download="kfx_key">download kfx_key</a></p>
</div>
<div id=fpwrap class=hidden>
 <label>Fingerprint (must match the Kindle screen):</label>
 <div class=fp id=fp></div>
</div>

<p><button id=go>Request enrollment</button> <span id=status class=muted></span></p>

<details><summary class=muted>Prefer the command line?</summary>
<pre>ssh-keygen -t ed25519 -f kfx_key -N "" -C laptop
curl -s --data-urlencode 'name=laptop' \
     --data-urlencode "key=$(cat kfx_key.pub)" \
     THISURL/enroll
ssh -i kfx_key -p 2222 kfx@THISHOST</pre></details>

<script src="/nacl.min.js"></script>
<script>
(function(){
 var $=function(id){return document.getElementById(id);};
 var te=new TextEncoder();
 function b64(bytes){var s="";for(var i=0;i<bytes.length;i++)s+=String.fromCharCode(bytes[i]);return btoa(s);}
 function concat(arrs){var n=0,i;for(i=0;i<arrs.length;i++)n+=arrs[i].length;var o=new Uint8Array(n),p=0;for(i=0;i<arrs.length;i++){o.set(arrs[i],p);p+=arrs[i].length;}return o;}
 function u32(n){return new Uint8Array([(n>>>24)&255,(n>>>16)&255,(n>>>8)&255,n&255]);}
 function S(b){if(typeof b==="string")b=te.encode(b);return concat([u32(b.length),b]);}
 function pubBlob(p){return concat([S("ssh-ed25519"),S(p)]);}
 // compact SHA-256 (validated against ssh-keygen -l)
 function sha256(msg){
  var K=[0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2];
  var h=[0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19];
  var ml=msg.length*8, wo=new Uint8Array(((msg.length+8)>>6)+1<<6);
  wo.set(msg); wo[msg.length]=0x80;
  var dv=new DataView(wo.buffer);
  dv.setUint32(wo.length-4, ml>>>0); dv.setUint32(wo.length-8, Math.floor(ml/0x100000000));
  var rotr=function(x,n){return (x>>>n)|(x<<(32-n));};
  for(var i=0;i<wo.length;i+=64){
   var w=new Uint32Array(64),j;
   for(j=0;j<16;j++)w[j]=dv.getUint32(i+j*4);
   for(j=16;j<64;j++){var s0=rotr(w[j-15],7)^rotr(w[j-15],18)^(w[j-15]>>>3),s1=rotr(w[j-2],17)^rotr(w[j-2],19)^(w[j-2]>>>10);w[j]=(w[j-16]+s0+w[j-7]+s1)|0;}
   var a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],hh=h[7];
   for(j=0;j<64;j++){var S1=rotr(e,6)^rotr(e,11)^rotr(e,25),ch=(e&f)^(~e&g),t1=(hh+S1+ch+K[j]+w[j])|0,S0=rotr(a,2)^rotr(a,13)^rotr(a,22),maj=(a&b)^(a&c)^(b&c),t2=(S0+maj)|0;hh=g;g=f;f=e;e=(d+t1)|0;d=c;c=b;b=a;a=(t1+t2)|0;}
   h=[h[0]+a|0,h[1]+b|0,h[2]+c|0,h[3]+d|0,h[4]+e|0,h[5]+f|0,h[6]+g|0,h[7]+hh|0];
  }
  var out=new Uint8Array(32),o=new DataView(out.buffer);
  for(i=0;i<8;i++)o.setUint32(i*4,h[i]>>>0);
  return out;
 }
 function sshFingerprint(pub32){return "SHA256:"+b64(sha256(pubBlob(pub32))).replace(/=+$/,"");}
 // openssh-key-v1 unencrypted private key (PROTOCOL.key)
 function opensshPrivateKey(seed32,pub32,comment){
  var magic=te.encode("openssh-key-v1\0");
  var priv64=concat([seed32,pub32]);
  var chk=crypto.getRandomValues(new Uint8Array(4));
  var ps=concat([chk,chk,S("ssh-ed25519"),S(pub32),S(priv64),S(comment||"")]);
  var pad=1,ex=[];while((ps.length+ex.length)%8!==0)ex.push(pad++);
  ps=concat([ps,new Uint8Array(ex)]);
  var body=concat([magic,S("none"),S("none"),S(""),u32(1),S(pubBlob(pub32)),S(ps)]);
  var b=b64(body),pem="-----BEGIN OPENSSH PRIVATE KEY-----\n",i;
  for(i=0;i<b.length;i+=70)pem+=b.slice(i,i+70)+"\n";
  return pem+"-----END OPENSSH PRIVATE KEY-----\n";
 }
 function showFp(pub32){$("fp").textContent=sshFingerprint(pub32);$("fpwrap").className="";}

 $("gen").onclick=function(){
  if(typeof nacl==="undefined"||!nacl.sign){$("genmsg").textContent="generator unavailable -- paste a key or use the command line.";return;}
  var name=($("name").value.trim()||"key").replace(/[^A-Za-z0-9._-]+/g,"_");
  var kp=nacl.sign.keyPair();               // secretKey = seed||pub, publicKey = pub
  var seed=kp.secretKey.slice(0,32), pub=kp.publicKey;
  var comment=($("name").value.trim()||"");
  var akline="ssh-ed25519 "+b64(pubBlob(pub))+(comment?(" "+comment):"");
  $("key").value=akline;
  var pem=opensshPrivateKey(seed,pub,comment);
  var url=URL.createObjectURL(new Blob([pem],{type:"application/octet-stream"}));
  var a=$("dllink"); a.href=url; a.download=name; $("dl").className="";
  showFp(pub);
  $("genmsg").textContent="key made. Save the private half, then Request.";
 };
 // paste path: show the fingerprint of a pasted ed25519 key too
 $("key").addEventListener("input",function(){
  var m=$("key").value.trim().match(/^ssh-ed25519\s+([A-Za-z0-9+/=]+)/);
  if(!m){$("fpwrap").className="hidden";return;}
  try{var raw=atob(m[1]);var u=new Uint8Array(raw.length),i;for(i=0;i<raw.length;i++)u[i]=raw.charCodeAt(i);
      // pub blob = 4+"ssh-ed25519"(11)+4+32 ; the trailing 32 bytes are the key
      showFp(u.slice(u.length-32));}catch(e){$("fpwrap").className="hidden";}
 });

 $("go").onclick=function(){
  var name=$("name").value.trim(), key=$("key").value.trim();
  if(!name){$("status").textContent="Enter a name.";return;}
  if(!/^(ssh-ed25519|ssh-rsa|ecdsa-sha2-|sk-)/.test(key)){$("status").textContent="Generate or paste a public key first.";return;}
  $("go").disabled=true;
  $("status").textContent="Waiting for approval on the Kindle...";
  var body="name="+encodeURIComponent(name)+"&key="+encodeURIComponent(key);
  fetch("/enroll",{method:"POST",headers:{"Content-Type":"application/x-www-form-urlencoded"},body:body})
   .then(function(r){return r.text().then(function(t){return {ok:r.ok,t:t};});})
   .then(function(r){$("status").textContent=r.t; if(!r.ok)$("go").disabled=false;})
   .catch(function(){$("status").textContent="Connection closed before approval.";$("go").disabled=false;});
 };
})();
</script>
HTML
}

# --- read the request line and headers ---------------------------------------
IFS= read -r _req || exit 0
_req=$(printf '%s' "$_req" | tr -d '\r')
_method=${_req%% *}; _rest=${_req#* }; _path=${_rest%% *}; _path=${_path%%\?*}

_clen=0
while IFS= read -r _h; do
    _h=$(printf '%s' "$_h" | tr -d '\r'); [ -z "$_h" ] && break
    case "$_h" in
        [Cc]ontent-[Ll]ength:*) _clen=$(printf '%s' "${_h#*:}" | tr -dc '0-9') ;;
    esac
done
case "$_clen" in ''|*[!0-9]*) _clen=0 ;; esac

# --- routing -----------------------------------------------------------------
if [ "$_method" = GET ]; then
    case "$_path" in
        /nacl.min.js)
            if [ -f "$LIBDIR/nacl.min.js" ]; then
                send "HTTP/1.0 200 OK" "application/javascript" < "$LIBDIR/nacl.min.js"
            else
                printf 'HTTP/1.0 404 Not Found\r\nConnection: close\r\n\r\n'
            fi ;;
        /|/enroll|/index.html) form_page ;;
        *) printf 'HTTP/1.0 404 Not Found\r\nConnection: close\r\n\r\n' ;;
    esac
    exit 0
fi

if [ "$_method" != POST ] || [ "$_path" != /enroll ]; then
    printf '%s\n' "POST name+key to /enroll, or open / in a browser." | send "HTTP/1.0 404 Not Found" "text/plain"
    exit 0
fi

[ "$_clen" -gt 0 ] && [ "$_clen" -le 4000 ] || { printf '%s\n' 'empty request' | send "HTTP/1.0 400 Bad Request" "text/plain"; exit 0; }
_body=$(head -c "$_clen")

# pull one field out of an application/x-www-form-urlencoded body and decode it
field() {   # $1 = field name, stdin = body
    _fv=$(printf '%s' "$_body" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1)
    _fv=$(printf '%s' "$_fv" | tr '+' ' ')
    printf '%b' "$(printf '%s' "$_fv" | sed 's/%/\\x/g')" 2>/dev/null
}
_name=$(field name | tr -d '\r\n' | sed 's/[^A-Za-z0-9 ._-]//g; s/^[[:space:]]*//; s/[[:space:]]*$//' | cut -c1-40)
_key=$(field key  | tr -d '\r\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

[ -n "$_name" ] || { printf '%s\n' 'give a name' | send "HTTP/1.0 400 Bad Request" "text/plain"; exit 0; }
case "$_key" in
    ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-*\ *) ;;
    *) printf '%s\n' 'that is not an SSH public key' | send "HTTP/1.0 400 Bad Request" "text/plain"; exit 0 ;;
esac

_id=$(date +%s).$$
printf 'name=%s\nip=%s\nkey=%s\n' "$_name" "${TCPREMOTEIP:-unknown}" "$_key" \
    > "$ENROLL_DIR/pending/$_id" 2>/dev/null

# --- wait for the owner to decide on the device ------------------------------
_n=0
while [ "$_n" -lt "$ENROLL_WAIT" ]; do
    if [ -f "$ENROLL_DIR/decision/$_id" ]; then
        _d=$(cat "$ENROLL_DIR/decision/$_id" 2>/dev/null)
        rm -f "$ENROLL_DIR/decision/$_id" "$ENROLL_DIR/pending/$_id" 2>/dev/null
        case "$_d" in
            approve) printf '%s\n' 'Approved -- your key is enrolled. Try: ssh -i kfx_key -p 2222 kfx@this-device' | send "HTTP/1.0 200 OK" "text/plain" ;;
            *)       printf '%s\n' 'Denied on the device.' | send "HTTP/1.0 403 Forbidden" "text/plain" ;;
        esac
        exit 0
    fi
    sleep 2; _n=$((_n + 2))
done
rm -f "$ENROLL_DIR/pending/$_id" 2>/dev/null
printf '%s\n' 'No approval on the device in time.' | send "HTTP/1.0 408 Request Timeout" "text/plain"
exit 0
