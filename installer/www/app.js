const token = location.hash.slice(1);
const panels = [...document.querySelectorAll(".panel")];
const next = document.querySelector("#next");

let step = 0;
let mode = "erase";
let disks = [];

const escapeHtml = (value = "") =>
  String(value).replace(
    /[&<>"']/g,
    character =>
      ({
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#39;",
      })[character],
  );

const api = async (action, body) => {
  let response;
  try {
    response = await fetch(`/cgi-bin/api?action=${action}`, {
      method: body ? "POST" : "GET",
      headers: {
        "X-Umbra-Token": token,
        "Content-Type": "application/json",
      },
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch {
    throw Error(
      "The local installer service disconnected. This is not an internet error. " +
        "Open /tmp/umbra-installer.log for details.",
    );
  }

  const text = await response.text();
  if (!response.ok) {
    throw Error(text || `Installer backend failed (HTTP ${response.status})`);
  }
  if (!text.trim()) {
    throw Error(
      "Installer backend exited without a response. " +
        "Open /tmp/umbra-installer.log for details.",
    );
  }
  try {
    return JSON.parse(text);
  } catch {
    throw Error(
      `Installer backend returned an invalid response: ${text.slice(0, 300)}`,
    );
  }
};

const diagnosticLog = async () => {
  const response = await fetch("/cgi-bin/api?action=log", {
    headers: { "X-Umbra-Token": token },
    cache: "no-store",
  });
  if (!response.ok) {
    throw Error(`Diagnostic log request failed (HTTP ${response.status})`);
  }
  return response.text();
};

const value = id => document.querySelector(`#${id}`)?.value || "";
const selected = name =>
  document.querySelector(`input[name="${name}"]:checked`)?.value || "";
const flatten = devices =>
  devices.flatMap(device => [device, ...flatten(device.children || [])]);
const formatSize = bytes =>
  bytes ? `${(bytes / 1073741824).toFixed(bytes >= 10737418240 ? 0 : 1)} GiB` : "—";
const mountText = device =>
  (device.mountpoints || []).filter(Boolean).join(", ") || "Not mounted";
const partitionType = device =>
  device.fstype || (device.type === "disk" ? "Disk" : "Unformatted");
const isEfi = device =>
  device.fstype === "vfat" ||
  device.parttype === "c12a7328-f81f-11d2-ba4b-00a0c93ec93b";

function diskName(device) {
  return [device.path, device.model || device.label].filter(Boolean).join(" — ");
}

function partitionRows(partitions, assignable) {
  if (!partitions.length) {
    return `<tr><td colspan="${assignable ? 7 : 5}" class="empty-cell">No partitions found</td></tr>`;
  }
  return partitions
    .map(device => {
      const path = escapeHtml(device.path);
      const roleControls = assignable
        ? `<td class="role-cell">
             <input type="radio" name="root" value="${path}"
               aria-label="Use ${path} as the UmbraOS root partition">
           </td>
           <td class="role-cell">
             <input type="radio" name="esp" value="${path}"
               aria-label="Use ${path} as the EFI System Partition"
               ${isEfi(device) ? "" : "disabled"}>
           </td>`
        : "";
      return `<tr>
        <th scope="row"><code>${path}</code></th>
        <td>${escapeHtml(formatSize(device.size))}</td>
        <td><span class="fs-badge">${escapeHtml(partitionType(device))}</span></td>
        <td>${escapeHtml(device.label || "—")}</td>
        <td class="mount-cell">${escapeHtml(mountText(device))}</td>
        ${roleControls}
      </tr>`;
    })
    .join("");
}

function storageTable(partitions, assignable = false) {
  return `<div class="partition-table-wrap">
    <table class="partition-table">
      <caption>${assignable ? "Assign partition roles" : "Current partition layout"}</caption>
      <thead>
        <tr>
          <th scope="col">Device</th>
          <th scope="col">Size</th>
          <th scope="col">Filesystem</th>
          <th scope="col">Label</th>
          <th scope="col">Mounted at</th>
          ${assignable ? '<th scope="col">Root</th><th scope="col">EFI</th>' : ""}
        </tr>
      </thead>
      <tbody>${partitionRows(partitions, assignable)}</tbody>
    </table>
  </div>`;
}

function renderEraseStorage(all) {
  const physicalDisks = all.filter(device => device.type === "disk");
  if (!physicalDisks.length) {
    return '<div class="storage-error" role="alert">No eligible installation disks were found.</div>';
  }
  const options = physicalDisks
    .map(
      device =>
        `<option value="${escapeHtml(device.path)}">${escapeHtml(diskName(device))} (${escapeHtml(formatSize(device.size))})</option>`,
    )
    .join("");
  const chosen = physicalDisks[0];
  return `<div class="storage-toolbar">
      <label for="disk">Installation disk
        <select id="disk">${options}</select>
      </label>
      <div class="destructive-note">
        The selected disk will be completely erased. UmbraOS creates a 1 GiB
        EFI partition and uses the remaining space for Btrfs.
      </div>
    </div>
    <div id="diskLayout">
      ${storageTable(chosen.children || [])}
    </div>`;
}

function renderManualStorage(all) {
  const partitions = all.filter(device => device.type === "part");
  return `<div class="role-guide">
      <div><b>Root</b><span>Formatted as Btrfs and used exclusively by UmbraOS.</span></div>
      <div><b>EFI</b><span>Existing FAT32 contents are preserved and reused.</span></div>
    </div>
    ${storageTable(partitions, true)}
    <div id="roleSummary" class="role-summary" aria-live="polite">
      Select one root partition and one EFI partition.
    </div>
    <div class="notice">
      Mounted selections are safely unmounted before installation. The installer
      never resizes partitions; prepare free space first.
    </div>`;
}

function updateDiskLayout() {
  const disk = flatten(disks).find(device => device.path === value("disk"));
  const layout = document.querySelector("#diskLayout");
  if (disk && layout) {
    layout.innerHTML = storageTable(disk.children || []);
  }
}

function updateRoleSummary() {
  const summary = document.querySelector("#roleSummary");
  if (!summary) return;
  const root = selected("root");
  const esp = selected("esp");
  summary.innerHTML = `<span>Root: <b>${escapeHtml(root || "Not selected")}</b></span>
    <span>EFI: <b>${escapeHtml(esp || "Not selected")}</b></span>`;
  document.querySelectorAll(".partition-table tbody tr").forEach(row => {
    const path = row.querySelector('input[name="root"]')?.value;
    row.classList.toggle("assigned-root", Boolean(path && path === root));
    row.classList.toggle("assigned-efi", Boolean(path && path === esp));
  });
}

function renderStorage() {
  const all = flatten(disks);
  const container = document.querySelector("#storageFields");
  container.innerHTML =
    mode === "erase" ? renderEraseStorage(all) : renderManualStorage(all);
  document.querySelector("#disk")?.addEventListener("change", updateDiskLayout);
  document
    .querySelectorAll('input[name="root"], input[name="esp"]')
    .forEach(input => input.addEventListener("change", updateRoleSummary));
}

async function loadDisks() {
  const container = document.querySelector("#storageFields");
  container.innerHTML = '<div class="storage-loading">Reading storage devices…</div>';
  try {
    const data = await api("disks");
    disks = (data.blockdevices || []).filter(
      device => device.path !== data.umbra_live_disk,
    );
    renderStorage();
  } catch (error) {
    container.innerHTML = `<div class="storage-error" role="alert">${escapeHtml(error.message)}</div>`;
  }
}

document.querySelectorAll(".choice").forEach(choice => {
  choice.addEventListener("click", () => {
    document.querySelectorAll(".choice").forEach(other => {
      const active = other === choice;
      other.classList.toggle("selected", active);
      other.setAttribute("aria-pressed", String(active));
    });
    mode = choice.dataset.mode;
    if (step === 1 && disks.length) renderStorage();
  });
});

document.querySelector("#refresh").addEventListener("click", loadDisks);

function validateStorage() {
  if (mode === "erase" && !value("disk")) {
    throw Error("Select an installation disk.");
  }
  if (mode === "manual") {
    if (!selected("root")) throw Error("Assign an UmbraOS root partition.");
    if (!selected("esp")) throw Error("Assign a FAT32 EFI System Partition.");
    if (selected("root") === selected("esp")) {
      throw Error("Root and EFI must be different partitions.");
    }
  }
}

function validateIdentity() {
  const username = value("username");
  const hostname = value("hostname");
  const password = value("password");
  if (!/^[a-z_][a-z0-9_-]{0,30}$/.test(username)) {
    throw Error("Invalid username");
  }
  if (!/^[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}$/.test(hostname)) {
    throw Error("Invalid hostname");
  }
  if (password.length < 8) {
    throw Error("Password must be at least 8 characters");
  }
  if (password !== value("password2")) {
    throw Error("Passwords do not match");
  }
}

function target() {
  return mode === "erase" ? value("disk") : selected("root");
}

function confirmationText() {
  return mode === "erase" ? `ERASE ${target()}` : `FORMAT ${target()}`;
}

function review() {
  const rows = [
    ["Mode", mode === "erase" ? "Erase whole disk" : "Manual / dual boot"],
    ["Target", target()],
    ["EFI partition", mode === "manual" ? selected("esp") : "Created automatically"],
    ["User", value("username")],
    ["Hostname", value("hostname")],
    ["Time zone", value("timezone")],
  ];
  document.querySelector("#summary").innerHTML = rows
    .map(
      ([label, detail]) =>
        `<div><span>${escapeHtml(label)}</span><b>${escapeHtml(detail)}</b></div>`,
    )
    .join("");
  document.querySelector("#confirmationText").textContent = confirmationText();
}

function show() {
  panels.forEach((panel, index) => {
    panel.classList.toggle("active", index === step);
    panel.setAttribute("aria-hidden", String(index !== step));
  });
  document.querySelector("#stepLabel").textContent = `${step + 1} / 4`;
  document.querySelector("#back").disabled = !step;
  next.textContent = step === 3 ? "Install UmbraOS" : "Continue";
  if (step === 1) loadDisks();
  if (step === 3) review();
}

document.querySelector("#back").addEventListener("click", () => {
  if (step) {
    step -= 1;
    show();
  }
});

next.addEventListener("click", async () => {
  try {
    if (step === 1) validateStorage();
    if (step === 2) validateIdentity();
    if (step < 3) {
      step += 1;
      show();
      return;
    }
    await install();
  } catch (error) {
    alert(error.message);
  }
});

async function install() {
  if (value("confirmation") !== confirmationText()) {
    throw Error("Confirmation text does not match");
  }
  next.disabled = true;
  document.querySelector("#back").disabled = true;
  document.querySelector("#progress").classList.remove("hidden");
  const resultPanel = document.querySelector("#result");
  resultPanel.textContent = "Starting installation diagnostics…";
  resultPanel.classList.remove("hidden");
  const refreshDiagnostics = async () => {
    try {
      const contents = await diagnosticLog();
      if (contents.trim()) {
        resultPanel.textContent = contents;
        resultPanel.scrollTop = resultPanel.scrollHeight;
      }
    } catch {
      // The primary install request reports backend disconnects. Keep the last
      // successful diagnostic snapshot instead of replacing it with poll noise.
    }
  };
  const diagnosticTimer = setInterval(refreshDiagnostics, 750);
  await refreshDiagnostics();
  const payload = {
    mode,
    disk: mode === "erase" ? value("disk") : null,
    root: mode === "manual" ? selected("root") : null,
    esp: mode === "manual" ? selected("esp") : null,
    username: value("username"),
    hostname: value("hostname"),
    timezone: value("timezone"),
    password: value("password"),
    confirmation: value("confirmation"),
  };
  try {
    const response = await api("install", payload);
    resultPanel.textContent = response.message;
    document.querySelector("#progress").classList.add("hidden");
    next.textContent = "Installation complete";
  } catch (error) {
    resultPanel.textContent = error.message;
    document.querySelector("#progress").classList.add("hidden");
    next.disabled = false;
  } finally {
    clearInterval(diagnosticTimer);
  }
}

show();
