-- Mainline model discovery: TCSKNM03 fivegram only. No legacy model fallback.
local fivegram=require("tiger_sentence_fivegram")
local M={}
function M.new(performance)
    local reader={BOS="\2",EOS="\3"}
    function reader.candidate_paths()
        local paths={}
        if rime_api then
            local user=rime_api.get_user_data_dir and rime_api.get_user_data_dir()
            local shared=rime_api.get_shared_data_dir and rime_api.get_shared_data_dir()
            if user and user~="" then
                paths[#paths+1]=user.."/models/sentence-fivegram-mobile.bin"
                paths[#paths+1]=user.."/sentence-fivegram-mobile.bin"
            end
            if shared and shared~="" then paths[#paths+1]=shared.."/models/sentence-fivegram-mobile.bin" end
        end
        return paths
    end
    function reader.load(path,limits)
        local file=assert(io.open(path,"rb"),"cannot open fivegram: "..path)
        local magic=file:read(8);file:close()
        assert(magic=="TCSKNM03","unsupported sentence model; install the Q8 fivegram")
        return fivegram.load(path,limits)
    end
    function reader.try_load(limits)
        local failures={}
        for _,path in ipairs(reader.candidate_paths()) do
            local file=io.open(path,"rb")
            if file then
                file:close()
                local ok,model=pcall(reader.load,path,limits)
                if ok then return model,nil end
                failures[#failures+1]=path..": "..tostring(model)
            end
        end
        return nil,#failures>0 and table.concat(failures," | ") or "no sentence fivegram model found"
    end
    return reader
end
return M
