-- TCSKNM03 paged character fivegram reader.
-- Pure Lua: intentionally avoids string.pack/unpack so LuaJIT 5.1 can use it.
local M = {}
local LN10 = math.log(10)
local HEADER_SIZE = 256
local BUCKET_META_SIZE = 40
local INDEX_ENTRY_SIZE = 16

local function bytes(s, p, n)
    local values = {string.byte(s, p, p + n - 1)}
    if #values ~= n then error("truncated TCSKNM03") end
    return values
end

local function u16(s, p)
    local a,b = string.byte(s,p,p+1)
    if not b then error("truncated u16") end
    return a + b * 256
end

local function u32(s, p)
    local a,b,c,d = string.byte(s,p,p+3)
    if not d then error("truncated u32") end
    return a + b*256 + c*65536 + d*16777216
end

local function i32(s, p)
    local value = u32(s,p)
    return value >= 2147483648 and value - 4294967296 or value
end

local function u64(s, p)
    local low = u32(s,p)
    local high = u32(s,p+4)
    local value = low + high * 4294967296
    if value > 9007199254740991 then error("TCSKNM03 offset exceeds exact Lua number") end
    return value
end

local function id_bytes(id)
    return string.char(id % 256, math.floor(id / 256))
end

local function history_id(history, index)
    return u16(history, (index - 1) * 2 + 1)
end

local function cache_new(limit)
    return {values={}, keys={}, next=1, count=0, limit=math.max(1, limit or 16)}
end

local function cache_put(cache, key, value)
    if cache.keys[cache.next] then
        -- Leave spare hash slots. Removing just one entry at a power-of-two
        -- capacity can make Lua rehash the entire table on every insertion.
        for i=0,math.ceil(cache.limit/4)-1 do
            local slot=(cache.next+i-1)%cache.limit+1
            local old=cache.keys[slot]
            if old then
                cache.values[old]=nil; cache.keys[slot]=nil
                cache.count=cache.count-1
            end
        end
    end
    cache.keys[cache.next] = key
    cache.values[key] = value
    cache.count=cache.count+1
    cache.next = cache.next % cache.limit + 1
    return value
end

local function read_at(file, offset, count)
    assert(file:seek("set", offset), "cannot seek TCSKNM03")
    local data = file:read(count)
    assert(data and #data == count, "truncated TCSKNM03")
    return data
end

local function decode_probability(q, quant)
    return quant.pmin + q * quant.pstep
end

local function decode_backoff(q, quant)
    if q == 0 then return 0.0 end
    return quant.bmin + (q - 1) * quant.bstep
end

local function parse_header(data, actual_size)
    assert(#data == HEADER_SIZE and data:sub(1,8) == "TCSKNM03", "not a TCSKNM03 model")
    local version=u32(data,9)
    assert((version == 1 or version == 2) and u32(data,13) == HEADER_SIZE, "unsupported TCSKNM03 version")
    assert(u64(data,17) == actual_size, "TCSKNM03 size mismatch")
    assert(u32(data,25) == 5 and u32(data,33) == 256, "invalid TCSKNM03 layout")
    local result = {
        file_size=actual_size, vocab_count=u32(data,29), index_stride=u32(data,37),
        vocab_offset=u64(data,41), vocab_bytes=u64(data,49),
        unknown=u16(data,57), bos=u16(data,59), eos=u16(data,61),
        sections={}, quant={}, version=version, quant_bytes=version==2 and 1 or 2
    }
    for i=0,3 do
        local p = 65 + i*24
        result.sections[i+2] = {
            directory_offset=u64(data,p),
            block_count=u64(data,p+8),
            record_count=u64(data,p+16)
        }
    end
    for i=0,4 do
        local p=161+i*16
        result.quant[i+1] = {
            pmin=i32(data,p)/1e7, pstep=u32(data,p+4)/(version==2 and 1e9 or 1e12),
            bmin=i32(data,p+8)/1e7, bstep=u32(data,p+12)/(version==2 and 1e9 or 1e12)
        }
    end
    return result
end

local function parse_bucket(data, p)
    return {
        blocks_offset=u64(data,p), blocks_bytes=u64(data,p+8),
        index_offset=u64(data,p+16), index_count=u32(data,p+24),
        block_count=u32(data,p+28), record_count=u64(data,p+32)
    }
end

function M.load(path, limits)
    local file = assert(io.open(path,"rb"), "cannot open fivegram: "..path)
    local ok, result = pcall(function()
        local actual = assert(file:seek("end"))
        local header = parse_header(read_at(file,0,HEADER_SIZE), actual)
        local qbytes=header.quant_bytes
        local read_q=qbytes==1 and string.byte or u16
        local successor_bytes=2+qbytes
        local directories={}
        for order=2,5 do
            local raw=read_at(file,header.sections[order].directory_offset,256*BUCKET_META_SIZE)
            local values={}
            for bucket=0,255 do values[bucket]=parse_bucket(raw,bucket*BUCKET_META_SIZE+1) end
            directories[order]=values
        end

        local vocab_raw=read_at(file,header.vocab_offset,header.vocab_bytes)
        local token_ids, tokens, unigram_p, unigram_b = {}, {}, {}, {}
        local p=1
        for id=0,header.vocab_count-1 do
            local length=u16(vocab_raw,p); p=p+2
            local token=vocab_raw:sub(p,p+length-1); p=p+length
            local pq=read_q(vocab_raw,p); local bq=read_q(vocab_raw,p+qbytes); p=p+qbytes*2
            token_ids[token]=id; tokens[id+1]=token
            unigram_p[id+1]=decode_probability(pq,header.quant[1])
            unigram_b[id+1]=decode_backoff(bq,header.quant[1])
        end
        assert(p-1 == #vocab_raw, "invalid TCSKNM03 vocabulary")

        local index_limit=(limits and limits.index_pages) or 64
        local page_limit=(limits and limits.page_bytes) or 8*1024*1024
        local index_cache=cache_new(index_limit)
        local context_limit=(limits and limits.context_entries) or 16384
        local step_limit=(limits and limits.logp_entries) or 32768
        local contexts,steps=cache_new(context_limit),cache_new(step_limit)
        local diagnostics=false
        local counters={step_hits=0,step_misses=0,context_hits=0,context_misses=0}
        local pages={values={}, keys={}, sizes={}, next=1, bytes=0, limit=page_limit, slots=math.max(8,index_limit*4)}

        local function page_put(key,value)
            while pages.values[key] == nil and pages.bytes + #value > pages.limit do
                local old=pages.keys[pages.next]
                if not old then break end
                pages.values[old]=nil
                pages.bytes=pages.bytes-(pages.sizes[old] or 0)
                pages.sizes[old]=nil
                pages.keys[pages.next]=nil
                pages.next=pages.next%pages.slots+1
            end
            local old=pages.keys[pages.next]
            if old then
                pages.values[old]=nil
                pages.bytes=pages.bytes-(pages.sizes[old] or 0)
                pages.sizes[old]=nil
            end
            pages.keys[pages.next]=key; pages.next=pages.next%pages.slots+1
            pages.values[key]=value; pages.sizes[key]=#value; pages.bytes=pages.bytes+#value
            return value
        end

        local function get_index(order,bucket,meta)
            local key=order*256+bucket
            local data=index_cache.values[key]
            if data then return data end
            data=meta.index_count>0 and read_at(file,meta.index_offset,meta.index_count*INDEX_ENTRY_SIZE) or ""
            return cache_put(index_cache,key,data)
        end

        local function compare_index(data, entry, history, start, context_len)
            local p=entry*INDEX_ENTRY_SIZE+1
            for i=0,context_len-1 do
                local a=u16(data,p+i*2)
                local b=history_id(history,start+i)
                if a<b then return -1 elseif a>b then return 1 end
            end
            return 0
        end

        local function compare_block(data,p,history,start,context_len)
            for i=0,context_len-1 do
                local a=u16(data,p+i*2)
                local b=history_id(history,start+i)
                if a<b then return -1 elseif a>b then return 1 end
            end
            return 0
        end

        local function get_page(key,offset,length)
            local data=pages.values[key]
            if not data then data=page_put(key,read_at(file,offset,length)) end
            return data
        end

        local function successor(meta,data,target,order)
            local lo,hi=0,meta.count
            while lo<hi do
                local mid=math.floor((lo+hi)/2)
                local value=u16(data,meta.successors+mid*successor_bytes)
                if value<target then lo=mid+1 else hi=mid end
            end
            if lo<meta.count and u16(data,meta.successors+lo*successor_bytes)==target then
                return decode_probability(read_q(data,meta.successors+lo*successor_bytes+2),header.quant[order]),meta.bow,true
            end
            return nil,meta.bow,false
        end

        local function lookup(order,history,start,target)
            local context_len=order-1
            -- Fixed-width IDs make history length part of the key's identity.
            -- Store offsets, not page strings: metadata cannot pin evicted pages.
            local context_key=history:sub(start*2-1,(start+context_len-1)*2)
            local cached=contexts.values[context_key]
            if cached~=nil then
                if diagnostics then counters.context_hits=counters.context_hits+1 end
                if cached==false then return nil,0.0,false end
                return successor(cached,get_page(cached.key,cached.offset,cached.length),target,order)
            end
            if diagnostics then counters.context_misses=counters.context_misses+1 end
            local first=history_id(history,start)
            local bucket=first%256
            local meta=directories[order][bucket]
            if not meta or meta.block_count==0 or meta.index_count==0 then
                cache_put(contexts,context_key,false); return nil,0.0,false
            end
            local index=get_index(order,bucket,meta)
            local low,high=0,meta.index_count
            while low<high do
                local mid=math.floor((low+high)/2)
                if compare_index(index,mid,history,start,context_len)<=0 then low=mid+1 else high=mid end
            end
            if low==0 then cache_put(contexts,context_key,false); return nil,0.0,false end
            local entry=low-1
            local ip=entry*INDEX_ENTRY_SIZE+1
            local offset=u64(index,ip+8)
            local finish=meta.index_offset
            if entry+1<meta.index_count then finish=u64(index,ip+INDEX_ENTRY_SIZE+8) end
            local page_key=order..":"..bucket..":"..entry
            local data=get_page(page_key,offset,finish-offset)
            local pos=1
            local block_header=context_len*2+qbytes+2
            while pos<=#data do
                local compared=compare_block(data,pos,history,start,context_len)
                local bowq=read_q(data,pos+context_len*2)
                local count=u16(data,pos+context_len*2+qbytes)
                local successors=pos+block_header
                if compared==0 then
                    local located={key=page_key,offset=offset,length=finish-offset,
                        successors=successors,count=count,bow=decode_backoff(bowq,header.quant[order-1])}
                    cache_put(contexts,context_key,located)
                    return successor(located,data,target,order)
                elseif compared>0 then
                    cache_put(contexts,context_key,false)
                    return nil,0.0,false
                end
                pos=successors+count*successor_bytes
            end
            cache_put(contexts,context_key,false)
            return nil,0.0,false
        end

        local function token_id(token)
            if token=="\2" then return header.bos end
            if token=="\3" then return header.eos end
            return token_ids[token]
        end

        local model={path=path,bytes=actual,format="TCSKNM03",version=header.version,quant_bits=qbytes*8,order=5,bos_id=header.bos}
        local function score_history(history,id)
            local count=math.floor(#history/2)
            local total=0.0
            local maximum=math.min(4,count)
            for context_len=maximum,1,-1 do
                local start=count-context_len+1
                local probability,bow,observed=lookup(context_len+1,history,start,id)
                if observed then return (total+probability)*LN10 end
                total=total+bow
            end
            local probability=unigram_p[id+1] or unigram_p[header.unknown+1]
            return (total+probability)*LN10
        end
        function model.step(lm1,lm2,lm3,lm4,count,target)
            assert(file,"closed TCSKNM03")
            local id=token_id(target) or header.unknown
            local history
            if count<=1 then history=id_bytes(lm1)
            elseif count==2 then history=id_bytes(lm2)..id_bytes(lm1)
            elseif count==3 then history=id_bytes(lm3)..id_bytes(lm2)..id_bytes(lm1)
            else history=id_bytes(lm4)..id_bytes(lm3)..id_bytes(lm2)..id_bytes(lm1) end
            local key=history..id_bytes(id)
            local score=steps.values[key]
            if score==nil then
                if diagnostics then counters.step_misses=counters.step_misses+1 end
                score=score_history(history,id)
                -- Do not cache exceptional/non-finite results.
                assert(score==score and math.abs(score)<math.huge,"non-finite TCSKNM03 score")
                cache_put(steps,key,score)
            elseif diagnostics then counters.step_hits=counters.step_hits+1 end
            return score,id,lm1,lm2,lm3,math.min(4,count+1)
        end
        function model.logp(prev2,prev1,target)
            local a,b,c,d,n=header.bos,0,0,0,1
            if prev2~="\2" then _,a,b,c,d,n=model.step(a,b,c,d,n,prev2) end
            if prev1~="\2" or prev2~="\2" then _,a,b,c,d,n=model.step(a,b,c,d,n,prev1) end
            return model.step(a,b,c,d,n,target)
        end
        function model.has_observed_bigram(previous,target)
            local left=token_id(previous); local right=token_id(target)
            if left==nil or right==nil then return false end
            local history=id_bytes(left)
            local _,_,observed=lookup(2,history,1,right)
            return observed
        end
        function model.configure_cache(values)
            page_limit=values.page_bytes or page_limit
            pages.limit=page_limit
            index_cache=cache_new(values.index_pages or index_limit)
            context_limit=values.context_entries or context_limit
            step_limit=values.logp_entries or step_limit
            contexts,steps=cache_new(context_limit),cache_new(step_limit)
            pages={values={},keys={},sizes={},next=1,bytes=0,limit=page_limit,slots=math.max(8,(values.index_pages or index_limit)*4)}
        end
        function model.cache_status()
            local entries=0
            for _ in pairs(pages.values) do entries=entries+1 end
            return {page_bytes=pages.bytes,page_limit=pages.limit,page_entries=entries,index_cache_limit=index_cache.limit,
                context_entries=contexts.count,context_limit=contexts.limit,
                step_entries=steps.count,step_limit=steps.limit}
        end
        function model.set_diagnostics(enabled) diagnostics=enabled==true end
        function model.diagnostics()
            local copy={}; for k,v in pairs(counters) do copy[k]=v end; return copy
        end
        function model.trim_caches()
            index_cache=cache_new(index_cache.limit)
            contexts,steps=cache_new(context_limit),cache_new(step_limit)
            pages={values={},keys={},sizes={},next=1,bytes=0,limit=page_limit,slots=pages.slots}
        end
        function model.close()
            if file then file:close(); file=nil end
            model.trim_caches()
        end
        return model
    end)
    if not ok then file:close(); error(result,0) end
    return result
end

return M
