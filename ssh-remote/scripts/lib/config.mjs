#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";

function die(message, code = 1) {
  process.stderr.write(message + "\n");
  process.exit(code);
}

function readConfig(file) {
  if (!fs.existsSync(file)) return { profiles: {} };
  const raw = fs.readFileSync(file, "utf8").replace(/^\uFEFF/, "");
  if (!raw.trim()) return { profiles: {} };
  const parsed = JSON.parse(raw);
  if (!parsed.profiles) parsed.profiles = {};
  return parsed;
}

function writeConfig(file, config) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(config, null, 2) + "\n", "utf8");
}

function resolveName(config, name) {
  let resolved = name || config.defaultProfile;
  if (!resolved) {
    const names = Object.keys(config.profiles);
    if (names.length === 1) resolved = names[0];
  }
  return resolved;
}

function getProfile(config, name) {
  const resolved = resolveName(config, name);
  if (!resolved || !config.profiles[resolved]) return null;
  const profile = Object.assign({ port: 22 }, config.profiles[resolved]);
  return { name: resolved, profile };
}

function safeProfile(profile) {
  const output = {};
  for (const [key, value] of Object.entries(profile)) {
    if (key === "password") output.hasPassword = true;
    else output[key] = value;
  }
  return output;
}

function shellQuote(value) {
  return "'" + String(value).replace(/'/g, "'\\''") + "'";
}

const [command, ...args] = process.argv.slice(2);

try {
  if (command === "profile") {
    const [configPath, name] = args;
    const config = readConfig(configPath);
    const result = getProfile(config, name);
    if (!result) process.exit(3);
    process.stdout.write(JSON.stringify(result.profile));
  } else if (command === "export") {
    const [configPath, name] = args;
    const config = readConfig(configPath);
    const result = getProfile(config, name);
    if (!result) process.exit(3);
    process.stdout.write(`profile=${shellQuote(result.name)}\n`);
    for (const [key, value] of Object.entries(result.profile)) {
      if (value === null || value === undefined) continue;
      process.stdout.write(`${key}=${shellQuote(value)}\n`);
    }
  } else if (command === "list") {
    const [configPath] = args;
    const config = readConfig(configPath);
    const profiles = Object.entries(config.profiles).map(([name, profile]) => ({
      name,
      host: profile.host,
      port: profile.port || 22,
      user: profile.user,
      workdir: profile.workdir,
      auth: profile.password || profile.passwordEnv ? "password" : profile.identityFile ? "key" : "agent",
    }));
    process.stdout.write(JSON.stringify({ defaultProfile: config.defaultProfile || null, profiles }));
  } else if (command === "get") {
    const [configPath, name] = args;
    const config = readConfig(configPath);
    const result = getProfile(config, name);
    if (!result) process.exit(3);
    process.stdout.write(JSON.stringify({ name: result.name, profile: safeProfile(result.profile) }));
  } else if (command === "set") {
    const [configPath, name, updatesJson] = args;
    if (!name) die("profile name is required");
    const config = readConfig(configPath);
    const updates = JSON.parse(updatesJson || "{}");
    for (const key of Object.keys(updates)) {
      if (updates[key] === null || updates[key] === undefined || updates[key] === "") delete updates[key];
    }
    if (updates.port) updates.port = Number(updates.port);
    config.profiles[name] = Object.assign({}, config.profiles[name] || {}, updates);
    if (updates.passwordEnv) delete config.profiles[name].password;
    else if (updates.password) delete config.profiles[name].passwordEnv;
    if (!config.defaultProfile) config.defaultProfile = name;
    writeConfig(configPath, config);
    process.stdout.write(JSON.stringify({ name, configPath }));
  } else if (command === "remove") {
    const [configPath, name] = args;
    if (!name) die("profile name is required");
    const config = readConfig(configPath);
    if (!config.profiles[name]) die(`Profile '${name}' not found.`);
    delete config.profiles[name];
    if (config.defaultProfile === name) config.defaultProfile = null;
    writeConfig(configPath, config);
    process.stdout.write(JSON.stringify({ name, configPath }));
  } else if (command === "default") {
    const [configPath, name] = args;
    if (!name) die("profile name is required");
    const config = readConfig(configPath);
    if (!config.profiles[name]) die(`Profile '${name}' not found.`);
    config.defaultProfile = name;
    writeConfig(configPath, config);
    process.stdout.write(JSON.stringify({ name, configPath }));
  } else {
    die("unknown command: " + command);
  }
} catch (error) {
  die(error && error.message ? error.message : String(error));
}
