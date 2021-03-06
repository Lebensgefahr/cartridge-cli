local t = require('luatest')
local g = t.group()

local clock = require('clock')
local fiber = require('fiber')
local fio = require('fio')
local ffi = require('ffi')
local fun = require('fun')

local Capture = require('luatest.capture')

local helper = require('test.helper')
local cmd = helper.cartridge_cmd

local function check_pid_running(pid)
    return ffi.C.kill(tonumber(pid), 0) == 0
end

local function wait_process_exit(pid, timeout)
    timeout = timeout or 2
    if type(pid) == 'table' then
        pid = tonumber(pid.pid)
    end
    local started_at = clock.time()
    while check_pid_running(pid) do
        if clock.time() - started_at > timeout then
            error('expected process to exit, but it does not')
        end
        fiber.sleep(0.1)
    end
end

-- Non-blocking os.execute() which fails if process does not exit.
local function os_execute(path, args, env, timeout)
    env = fun.chain(os.environ(), env or {}):tomap()
    local process = t.Process:start(fio.abspath(path), args, env)
    wait_process_exit(process, timeout)
    return process
end

local function read_file(path)
    local file = assert(fio.open(path))
    local result = assert(file:read())
    file:close()
    return result
end

local function concat(...)
    return fun.chain(...):totable()
end

local RUN_DIR = fio.pathjoin(helper.tempdir, 'test_run')
local INSTANCE_SCRIPT = 'test/instances/init.lua'
local TEST_OPTS = {'--run-dir', RUN_DIR}
local SIMPLE_INSTANCE_OPTS = concat({'--script',INSTANCE_SCRIPT }, TEST_OPTS)
local INSTANCE_PIDFILE = fio.pathjoin(RUN_DIR, 'cartridge-cli.test_name.pid')

g.before_each(function() fio.rmtree(RUN_DIR) end)

g.test_start_stop = function()
    local starter = os_execute(cmd, concat({'start', '.test_name', '-d'}, SIMPLE_INSTANCE_OPTS))
    local pid = tonumber(read_file(INSTANCE_PIDFILE))
    t.assert_not_equals(pid, starter.pid)
    t.assert(check_pid_running(pid))
    os_execute(cmd, concat({'stop', '.test_name'}, TEST_OPTS))
    t.assert_not(check_pid_running(pid))
    t.assert_not(fio.stat(INSTANCE_PIDFILE))
end

g.test_start_stop_with_options_in_env = function()
    local starter = os_execute(cmd, {'start', '.test_name', '-d'}, {
        TARANTOOL_SCRIPT = INSTANCE_SCRIPT,
        TARANTOOL_RUN_DIR = RUN_DIR,
    })
    local pid = tonumber(read_file(INSTANCE_PIDFILE))
    t.assert_not_equals(pid, starter.pid)
    t.assert(check_pid_running(pid))
    os_execute(cmd, {'stop', '.test_name'}, {TARANTOOL_RUN_DIR = RUN_DIR})
    t.assert_not(check_pid_running(pid))
end

g.test_start_foreground = function()
    local starter = t.Process:start(
        cmd,
        concat({'start', '.test_name'}, SIMPLE_INSTANCE_OPTS),
        os.environ()
    )
    local pid = t.helpers.retrying({}, function()
        return tonumber(read_file(INSTANCE_PIDFILE))
    end)
    t.assert_equals(pid, starter.pid)
    t.assert(check_pid_running(pid))
    starter:kill()
    t.helpers.retrying({}, function() t.assert_not(check_pid_running(pid)) end)
end

local function assert_start_stop_all(config_opts, instance_names)
    local starter = os_execute(cmd, concat({'start', '-d'}, config_opts, SIMPLE_INSTANCE_OPTS), nil, 5)
    instance_names = instance_names or
        {'test_app.storage_1', 'test_app.storage_2', 'test_app.router_1'}
    local pids_by_instance_name = {}
    for _, instance_name in pairs(instance_names) do
        local pid = tonumber(read_file('tmp/test_run/' .. instance_name .. '.pid'))
        t.assert_not_equals(pid, starter.pid)
        t.assert(check_pid_running(pid))
        pids_by_instance_name[instance_name] = pid
    end
    os_execute(cmd, concat({'stop'}, config_opts, TEST_OPTS))
    for _, instance_name in pairs(instance_names) do
        t.assert_not(fio.stat('tmp/test_run/' .. instance_name .. '.pid'))
        t.assert_not(check_pid_running(pids_by_instance_name[instance_name]))
    end
end

g.test_start_stop_all = function()
    assert_start_stop_all({'test_app', '--cfg', 'test/instances/instances.yml'})
end

g.test_start_stop_all_with_split_config = function()
    assert_start_stop_all({'test_app', '--cfg', 'test/instances/config_multiple'})
end

g.test_start_stop_all_with_app_name_from_rockspec = function()
    assert_start_stop_all(
        {'--cfg', 'test/instances/instances.yml'},
        {'cartridge-cli.cli_instance_1', 'cartridge-cli.cli_instance_2'}
    )
end

g.test_start_stop_all_with_invalid_app_name = function()
    local capture = Capture:new()
    capture:wrap(true, function()
        os_execute(cmd, concat(
            {'start', 'tdg', '--cfg', 'test/instances/config_multiple', '-d'}, SIMPLE_INSTANCE_OPTS
        ))
    end)
    t.assert_str_contains(capture:flush().stderr, 'No configured instances found for app tdg')
end

g.test_start_stop_all_with_apps_path = function()
    assert_start_stop_all(
        {'instances', '--cfg', 'test/instances/instances.yml', '--apps-path', fio.abspath('test')},
        {'instances.app_path_1', 'instances.app_path_2'}
    )
end
