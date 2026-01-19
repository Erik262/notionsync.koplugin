local md5 = require("ffi/sha2").md5

local GetHighlights = {}

-- Process the document and return a payload of book metadata and highlights
function GetHighlights.transform(doc, raw_annotations)
    if not doc then return nil, "No document" end
    if not raw_annotations or next(raw_annotations) == nil then return nil, "No annotations" end

    -- 1. Get Book Metadata
    local props = doc:getProps()
    
    -- DEBUG: Print all props keys to see what we actually have
    local logger = require("custom_logger")
    if props then
        local debug_keys = ""
        for k, v in pairs(props) do debug_keys = debug_keys .. k .. "=" .. tostring(v) .. "; " end
        logger.info("NotionSync Props: " .. debug_keys)
    else
        logger.info("NotionSync Props: NIL")
    end

    -- Also check doc.info directly if possible
    if doc.info then
        local json = require("json")
        -- Safe encode just top level to avoid recursion issues
        pcall(function() logger.info("NotionSync DocInfo: " .. json.encode(doc.info)) end)
    else
        logger.info("NotionSync DocInfo: NIL")
    end

    local book_title = nil
    
    -- Try to get title from props
    if props and props.title then
        book_title = props.title
    end
    
    -- Fallback 1: Try doc.info
    if (not book_title or book_title == "") and doc.info then
        if doc.info.title then
            book_title = doc.info.title
        elseif doc.info.summary and doc.info.summary.title then
            book_title = doc.info.summary.title
        end
    end
    
    -- Fallback 2: Try to get from docsettings
    if not book_title or book_title == "" then
        local file_path = doc.file or ""
        if file_path ~= "" then
            pcall(function()
                local DocSettings = require("docsettings")
                local doc_settings = DocSettings:open(file_path)
                if doc_settings then
                    -- Try various metadata locations in docsettings
                    local metadata = doc_settings:readSetting("doc_props") 
                        or doc_settings:readSetting("metadata")
                        or doc_settings:readSetting("props")
                    
                    if metadata then
                        if type(metadata) == "table" and metadata.title then
                            book_title = metadata.title
                        end
                    end
                end
            end)
        end
    end
    
    -- Fallback 3: Extract from filename
    if (not book_title or book_title == "") and doc.file then
        local filename = doc.file:match("([^/]+)$")
        if filename then
            -- Remove extension
            book_title = filename:gsub("%.[^%.]+$", "")
        end
    end
    
    book_title = book_title or "Unknown Title"
    
    -- Try multiple casing/plural variations for safety
    local raw_author = props and (props.authors or props.author or props.Authors or props.Author) or nil
    local book_author = "Unknown Author"
    
    if type(raw_author) == "table" then
        book_author = table.concat(raw_author, "; ")
    elseif type(raw_author) == "string" and raw_author ~= "" then
        -- Normalize separators: " & " -> "; "
        book_author = raw_author:gsub(" & ", "; "):gsub(" and ", "; ")
    end
    
    -- Extract ISBN robustly
    -- Log shows: identifiers=google:...\nisbn:978...
    local book_isbn = props.isbn
    if not book_isbn and props.identifiers then
        -- Lowercase and look for "isbn:" anywhere (handling newlines)
        local ids = props.identifiers:lower()
        -- Match isbn: followed by digits/dashes/x, possibly after a newline or start
        book_isbn = ids:match("isbn:(%d[%d%-]*[xX]?)")
    end
    book_isbn = book_isbn or ""

    -- Extract Language
    -- Log shows: language=en
    local book_language = props.language
    if not book_language and doc.info and doc.info.language then
        book_language = doc.info.language
    end
    if not book_language and props.lang then book_language = props.lang end
    book_language = book_language or "Unknown"

    -- Extract Extra Stats
    local total_pages = 0
    -- Priority based on logs: doc.info.number_of_pages
    if doc.info and doc.info.number_of_pages then
        total_pages = doc.info.number_of_pages
    elseif doc.info and doc.info.summary and doc.info.summary.num_pages then
        total_pages = doc.info.summary.num_pages
    elseif props.doc_pages then 
        total_pages = props.doc_pages
    elseif props.pages then
        total_pages = props.pages
    end

    -- Start Reading Date
    -- If doc.info.summary is missing, we try fallback to 'created_at' of the first highlight
    local start_date = ""
    if doc.info and doc.info.summary and doc.info.summary.modified then
        start_date = doc.info.summary.modified
    end
    
    local file_path = doc.file or ""

    -- 2. Transform Data
    local clean_highlights = {}
    
    local first_highlight_date = nil
    
    for _, item in pairs(raw_annotations) do
        -- Generate ID: md5(filepath + datetime)
        local created_at = item.datetime or ""
        
        -- Capture first highlight date as fallback for start_reading
        if created_at ~= "" then
             if not first_highlight_date or created_at < first_highlight_date then
                 first_highlight_date = created_at
             end
        end

        local id_source = file_path .. created_at
        local unique_id = md5(id_source)

        -- Handle Updated At logic
        local updated_at = item.datetime_updated
        if not updated_at or updated_at == "" then
            updated_at = created_at
        end

        local entry = {
            id = unique_id,
            chapter = item.chapter or "",
            text = item.text or "",
            page = item.pageno or item.page,
            note = item.note, -- Lua ignores if nil
            created_at = created_at,
            updated_at = updated_at
        }

        table.insert(clean_highlights, entry)
    end
    
    -- Fallback Start Date
    if start_date == "" and first_highlight_date then
        start_date = first_highlight_date
    end

    -- 3. Return Final Payload
    return {
        author = book_author,
        title = book_title,
        isbn = book_isbn,
        language = book_language,
        pages = total_pages,
        start_date = start_date,
        highlights = clean_highlights
    }
end

return GetHighlights