local M = {}

M.token = nil
M.notifications = {}

-- Setup function
function M.setup()
  M.token = os.getenv("GITHUB_TOKEN")
  if M.token == "" then
    vim.notify("[notifyme] No GitHub token set!", vim.log.levels.ERROR)
  end
end

-- Fetch GitHub notifications and show in Telescope
M.fetch_notifications = function()
  if not M.token or M.token == "" then
    vim.notify("[notify_me] Missing GitHub token. Run setup() or set GITHUB_TOKEN.", vim.log.levels.ERROR)
    return
  end

  vim.notify("[notify_me] Fetching GitHub notifications...", vim.log.levels.INFO)

  local curl = require("plenary.curl")

  -- Step 1: Fetch API Rate Limit
  curl.get("https://api.github.com/rate_limit", {
    headers = {
      ["Authorization"] = "token " .. M.token,
      ["Accept"] = "application/vnd.github+json",
      ["User-Agent"] = "Neovim-NotifyMe",
    },
    callback = vim.schedule_wrap(function(rate_response)
      if not rate_response or rate_response.status ~= 200 then
        vim.notify(
          ("[notify_me] Failed to get rate limit (HTTP %d)"):format(rate_response and rate_response.status or 0),
          vim.log.levels.ERROR)
        return
      end

      local rate_data = vim.json.decode(rate_response.body)
      local remaining_requests = rate_data.rate.remaining or "N/A"

      -- Step 2: Fetch Notifications
      curl.get("https://api.github.com/notifications?all=false", {
        headers = {
          ["Authorization"] = "token " .. M.token,
          ["Accept"] = "application/vnd.github+json",
          ["User-Agent"] = "Neovim-NotifyMe",
        },
        callback = vim.schedule_wrap(function(notif_response)
          if not notif_response or notif_response.status ~= 200 then
            vim.notify(("[notify_me] HTTP %d: %s"):format(notif_response.status, notif_response.body),
              vim.log.levels.ERROR)
            return
          end

          local data = vim.json.decode(notif_response.body)
          if not data or #data == 0 then
            vim.notify("[notify_me] No new unread GitHub notifications.", vim.log.levels.INFO)
            return
          end

          -- Prepare notifications for Telescope
          M.notifications = {}

          -- ✅ Add API Call Count at the Top
          table.insert(M.notifications, {
            value = "API Rate Limit",
            display = "💡 Remaining API Requests: " .. remaining_requests,
            ordinal = "API Rate Limit",
          })

          for _, item in ipairs(data) do
            -- Ensure required fields exist
            local repo_name = item.repository and item.repository.full_name
            local title = item.subject and item.subject.title
            local notification_type = item.subject and item.subject.type
            local url = item.subject and item.subject.url
            local reason = item.reason or "Unknown"
            local thread_id = item.url and item.url:match("threads/(%d+)") or nil

            if not repo_name or not title or not notification_type or not url then
              print("[DEBUG] Skipping incomplete notification:", vim.inspect(item))
              goto continue
            end

            print("[DEBUG] Extracted Thread ID:", thread_id)
            print("[DEBUG] Reason for notification:", reason)
            print("[DEBUG] Repo Name:", repo_name)

            table.insert(M.notifications, {
              value = url,
              display = ("[%s] %s (%s) - Reason: %s"):format(repo_name, title, notification_type, reason),
              ordinal = title .. " " .. repo_name,
              repo = repo_name,
              title = title,
              type = notification_type,
              url = url,
              id = thread_id,
              reason = reason,
            })

            ::continue:: -- ✅ Skip invalid entries
          end

          M.open_telescope()
        end),
      })
    end),
  })
end

-- Function to open Telescope UI
M.open_telescope = function()
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers.new({}, {
    prompt_title = "GitHub Notifications",
    finder = finders.new_table({
      results = M.notifications,
      entry_maker = function(entry)
        return {
          value = entry.value,
          display = ("[%s] %s (%s) - Reason: %s"):format(
            entry.repo or "Unknown Repo",
            entry.title or "No Title",
            entry.type or "Unknown",
            entry.reason or "Unknown"
          ),
          ordinal = (entry.title or "") .. " " .. (entry.repo or ""),
          repo = entry.repo or "Unknown Repo",
          title = entry.title or "No Title",
          type = entry.type or "Unknown",
          url = entry.url or "Unknown URL",
          id = entry.id,
          reason = entry.reason or "Unknown",
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      -- ✅ Press "Enter" to open in browser
      map("i", "<CR>", function()
        local selection = action_state.get_selected_entry()
        if selection and selection.url then
          local web_url = selection.url:gsub("api.github.com/repos/", "github.com/"):gsub("/pulls/", "/pull/")
          vim.fn.jobstart({ "xdg-open", web_url }, { detach = true })
          vim.notify("Opening " .. web_url, vim.log.levels.INFO)
        end
        actions.close(prompt_bufnr)
      end)

      -- ✅ Press "r" to refresh notifications
      map("i", "r", function()
        actions.close(prompt_bufnr)
        M.fetch_notifications()
      end)

      -- ✅ Press "x" to mark as read
      map("i", "x", function()
        local selection = action_state.get_selected_entry()
        print("[DEBUG] Selected Entry:", vim.inspect(selection)) -- ✅ Debugging

        if selection and selection.id then
          M.mark_as_read(selection.id)
        else
          vim.notify("[notify_me] No valid notification selected.", vim.log.levels.WARN)
        end
      end)

      return true
    end,
    previewer = require("telescope.previewers").new_buffer_previewer({
      define_preview = function(self, entry)
        local preview_content = {
          "📦 Repository: " .. (entry.repo or "Unknown Repo"),
          "🔖 Title: " .. (entry.title or "No Title"),
          "📝 Type: " .. (entry.type or "Unknown"),
          "🔔 Reason: " .. (entry.reason or "Unknown"),
          "🌍 URL: " .. (entry.url or "Unknown URL"),
          "",
          "Press <Enter> to open in browser.",
          "Press 'x' to mark as read.",
        }
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, preview_content)
      end,
    }),
  }):find()
end

M.mark_as_read = function(notification_id)
  if not M.token or M.token == "" then
    vim.notify("[notify_me] Missing GitHub token. Cannot mark as read.", vim.log.levels.ERROR)
    return
  end

  local curl = require("plenary.curl")

  curl.patch("https://api.github.com/notifications/threads/" .. notification_id, {
    headers = {
      ["Authorization"] = "token " .. M.token,
      ["Accept"] = "application/vnd.github+json",
      ["User-Agent"] = "Neovim-NotifyMe",
    },
    callback = vim.schedule_wrap(function(response)
      if response and response.status == 205 then
        vim.notify("[notify_me] Notification marked as read.", vim.log.levels.INFO)
        -- ✅ Refresh the UI after marking as read
        M.fetch_notifications()
      else
        vim.notify("[notify_me] Failed to mark as read.", vim.log.levels.ERROR)
      end
    end),
  })
end

return M
