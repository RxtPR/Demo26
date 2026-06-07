#!/usr/bin/env python3
import html
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


BASE_DIR = Path(__file__).resolve().parent
DEPLOY_SCRIPT = BASE_DIR / "deploy_inf.sh"
DEFAULT_PORT = 8088

DEFAULTS = {
    "isp_updated": "yes",
    "domain": "au-team.irpo",
    "samba_admin_pass": "P@ssw0rd",
    "hq_user_pass": "P@ssw0rd",
    "web_auth_user": "WEB",
    "web_auth_pass": "P@ssw0rd",
    "db_user": "web",
    "db_pass": "P@ssw0rd",
    "db_name": "webdb",
    "docker_db_name": "testdb",
    "docker_db_user": "testc",
    "docker_db_pass": "P@ssw0rd",
    "docker_db_root_pass": "P@ssw0rd",
    "docker_db_image": "mariadb:10.11",
    "testapp_image": "site:latest",
    "docker_db_container": "db",
    "testapp_container": "tespapp",
    "testapp_port": "8080",
    "ssh_forward_port": "2026",
    "chrony_stratum": "5",
    "sshuser_pass": "P@ssw0rd",
    "net_admin_pass": "P@ssw0rd",
    "root_pass": "toor",
    "isp_ip": "172.16.1.1",
    "hq_rtr_ip": "172.16.1.2",
    "br_rtr_ip": "172.16.2.2",
    "hq_srv_ip": "192.168.10.2",
    "br_srv_ip": "192.168.2.2",
    "hq_cli_ip": "192.168.20.2",
}

QUESTIONS = [
    ("domain", "Имя домена", "Настройте контроллер домена Samba DC: имя домена au-team.irpo."),
    ("samba_admin_pass", "Пароль Administrator Samba", "Samba DC: пароль администратора используется для provision и DNS-записей."),
    ("hq_user_pass", "Пароль hquser1..5", "Создайте 5 пользователей для офиса HQ: hquser1, hquser2 и т.д."),
    ("web_auth_user", "Логин web-auth nginx", "Web-based аутентификация: логин WEB с паролем P@ssw0rd."),
    ("web_auth_pass", "Пароль web-auth nginx", "Файл /etc/nginx/.htpasswd используется как хранилище учетных записей."),
    ("db_name", "БД веб-приложения HQ-SRV", "Импортируйте dump.sql в базу данных webdb."),
    ("db_user", "Пользователь БД HQ-SRV", "Создайте пользователя web с паролем P@ssw0rd."),
    ("db_pass", "Пароль БД HQ-SRV", "В index.php укажите правильные учетные данные подключения к БД."),
    ("docker_db_name", "БД docker-приложения", "Docker: имя БД testdb."),
    ("docker_db_user", "Пользователь БД docker", "Docker: пользователь testc с паролем P@ssw0rd."),
    ("docker_db_pass", "Пароль БД docker", "Docker: пароль пользователя базы данных."),
    ("docker_db_root_pass", "Root-пароль БД docker", "Docker stack: пароль root для mariadb."),
    ("docker_db_image", "Образ БД docker", "Трогать только если не работает сайт! Используйте образ mariadb_latest из директории docker Additional.iso."),
    ("testapp_image", "Образ приложения docker", "Трогать только если не работает сайт! Используйте образ site_latest из директории docker Additional.iso."),
    ("docker_db_container", "Контейнер БД", "Контейнер с базой данных должен называться db."),
    ("testapp_container", "Контейнер приложения", "Основной контейнер testapp должен называться tespapp."),
    ("testapp_port", "Порт приложения", "Приложение должно быть доступно извне через порт 8080."),
    ("ssh_forward_port", "Порт SSH-проброса", "Пробросьте порт 2026 для подключения к серверам по SSH."),
    ("chrony_stratum", "Стратум chrony", "Настройте службу сетевого времени на ISP: стратум сервера - 5."),
    ("sshuser_pass", "Пароль sshuser", "Используется для рассылки SSH-ключей Ansible на серверы."),
    ("net_admin_pass", "Пароль net_admin", "Используется для рассылки SSH-ключей Ansible на маршрутизаторы."),
    ("root_pass", "Пароль root", "Используется для рассылки SSH-ключей Ansible на root-хосты."),
]

IP_QUESTIONS = [
    ("isp_ip", "ISP", "Маршрутизатор ISP, NTP-сервер и nginx reverse proxy."),
    ("hq_rtr_ip", "HQ-RTR", "Маршрутизатор HQ-RTR в inventory Ansible и DNS Samba."),
    ("br_rtr_ip", "BR-RTR", "Маршрутизатор BR-RTR в inventory Ansible и DNS Samba."),
    ("hq_srv_ip", "HQ-SRV", "Apache, MariaDB, RAID/NFS и DNS Samba."),
    ("br_srv_ip", "BR-SRV", "Samba DC, docker stack и локальный Ansible."),
    ("hq_cli_ip", "HQ-CLI", "Клиент HQ-CLI, sudoers и NFS automount."),
]


state = {
    "running": False,
    "exit_code": None,
    "started_at": None,
    "log": [],
}
lock = threading.Lock()


def local_ip() -> str:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.connect(("8.8.8.8", 80))
            return sock.getsockname()[0]
    except OSError:
        return "127.0.0.1"


def choose_port(start: int) -> int:
    port = start
    while True:
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                sock.bind(("", port))
            return port
        except OSError:
            port += 1


def append_log(line: str) -> None:
    with lock:
        state["log"].append(line)


def shell_answer(value: str) -> str:
    return str(value).replace("\r", "").replace("\n", " ").strip()


def build_answers(data: dict) -> str:
    order = [
        "isp_updated",
        "domain",
        "samba_admin_pass",
        "hq_user_pass",
        "web_auth_user",
        "web_auth_pass",
        "db_user",
        "db_pass",
        "db_name",
        "docker_db_name",
        "docker_db_user",
        "docker_db_pass",
        "docker_db_root_pass",
        "docker_db_image",
        "testapp_image",
        "docker_db_container",
        "testapp_container",
        "testapp_port",
        "ssh_forward_port",
        "chrony_stratum",
        "sshuser_pass",
        "net_admin_pass",
        "root_pass",
    ]
    return "\n".join(shell_answer(data.get(key, DEFAULTS[key])) for key in order) + "\n"


def make_script_for_run(data: dict) -> Path:
    if not data.get("ips_changed"):
        return DEPLOY_SCRIPT

    text = DEPLOY_SCRIPT.read_text(encoding="utf-8")
    replacements = {
        DEFAULTS["isp_ip"]: data.get("isp_ip", DEFAULTS["isp_ip"]),
        DEFAULTS["hq_rtr_ip"]: data.get("hq_rtr_ip", DEFAULTS["hq_rtr_ip"]),
        DEFAULTS["br_rtr_ip"]: data.get("br_rtr_ip", DEFAULTS["br_rtr_ip"]),
        DEFAULTS["hq_srv_ip"]: data.get("hq_srv_ip", DEFAULTS["hq_srv_ip"]),
        DEFAULTS["br_srv_ip"]: data.get("br_srv_ip", DEFAULTS["br_srv_ip"]),
        DEFAULTS["hq_cli_ip"]: data.get("hq_cli_ip", DEFAULTS["hq_cli_ip"]),
    }
    for old, new in replacements.items():
        text = text.replace(old, shell_answer(new))

    fd, path = tempfile.mkstemp(prefix="deploy_inf_web_", suffix=".sh")
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.chmod(path, 0o755)
    return Path(path)


def run_deploy(data: dict) -> None:
    script_path = make_script_for_run(data)
    answers = build_answers(data)
    append_log(f"$ bash {script_path}\n")
    if os.geteuid() != 0:
        append_log("ВНИМАНИЕ: веб-мастер запущен не от root, deploy_inf.sh завершится на проверке root.\n")
    if script_path != DEPLOY_SCRIPT:
        append_log(f"IP изменены: выполняется временная копия {script_path}, оригинальный deploy_inf.sh не изменен.\n")

    try:
        process = subprocess.Popen(
            ["bash", str(script_path)],
            cwd=str(BASE_DIR),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        assert process.stdin is not None
        assert process.stdout is not None
        process.stdin.write(answers)
        process.stdin.close()
        for line in process.stdout:
            append_log(line)
        code = process.wait()
        append_log(f"\n=== Завершено с кодом {code} ===\n")
    except Exception as exc:
        code = 1
        append_log(f"\nОШИБКА ЗАПУСКА: {exc}\n")
    finally:
        if script_path != DEPLOY_SCRIPT:
            try:
                script_path.unlink()
            except OSError:
                pass
        with lock:
            state["running"] = False
            state["exit_code"] = code


def page() -> str:
    def input_row(key: str, label: str, help_text: str) -> str:
        value = html.escape(DEFAULTS[key])
        return f"""
        <label class="field">
          <span>{html.escape(label)} <button class="hint" type="button" data-tip="{html.escape(help_text)}">?</button></span>
          <input name="{html.escape(key)}" type="text" value="{value}" autocomplete="off">
        </label>
        """

    main_fields = []
    for key, label, help_text in QUESTIONS:
        main_fields.append(input_row(key, label, help_text))

    ip_fields = []
    for key, label, help_text in IP_QUESTIONS:
        ip_fields.append(input_row(key, label, help_text))

    return f"""<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Deploy INF</title>
  <style>
    :root {{ --bg:#f6f7f9; --text:#1c2430; --muted:#657082; --line:#d8dde6; --accent:#1769aa; --ok:#147a3f; --bad:#b3261e; }}
    * {{ box-sizing:border-box; }}
    body {{ margin:0; font:15px/1.45 system-ui, -apple-system, Segoe UI, sans-serif; color:var(--text); background:var(--bg); }}
    header {{ padding:18px 24px; background:#ffffff; border-bottom:1px solid var(--line); position:sticky; top:0; z-index:2; }}
    h1 {{ margin:0; font-size:22px; }}
    main {{ display:grid; grid-template-columns:minmax(360px, 0.9fr) minmax(420px, 1.1fr); gap:18px; padding:18px; }}
    section {{ background:#fff; border:1px solid var(--line); border-radius:8px; padding:16px; }}
    .grid {{ display:grid; grid-template-columns:1fr 1fr; gap:12px; }}
    .field {{ display:grid; gap:6px; min-width:0; }}
    .field span {{ color:var(--muted); font-size:13px; }}
    input, select {{ width:100%; padding:10px 11px; border:1px solid var(--line); border-radius:6px; font:inherit; background:#fff; }}
    input:focus, select:focus {{ outline:2px solid #b9dcff; border-color:var(--accent); }}
    .hint {{ width:20px; height:20px; border:1px solid var(--line); border-radius:50%; background:#fff; color:var(--accent); cursor:help; font-weight:700; }}
    .hint:hover::after {{ content:attr(data-tip); position:absolute; max-width:360px; margin:24px 0 0 -20px; padding:10px 12px; background:#1f2937; color:#fff; border-radius:6px; font-weight:400; z-index:5; box-shadow:0 8px 24px #0002; }}
    .switch {{ display:flex; align-items:center; gap:8px; margin:12px 0; color:var(--muted); }}
    .switch input {{ width:auto; }}
    #ipBox {{ display:none; }}
    .actions {{ display:flex; align-items:center; gap:12px; margin-top:14px; }}
    button.primary {{ border:0; background:var(--accent); color:#fff; padding:11px 16px; border-radius:6px; font:inherit; cursor:pointer; }}
    button.primary:disabled {{ opacity:.55; cursor:not-allowed; }}
    #status {{ color:var(--muted); }}
    pre {{ margin:0; min-height:560px; max-height:calc(100vh - 150px); overflow:auto; background:#101419; color:#d7e0ea; padding:14px; border-radius:6px; white-space:pre-wrap; font:13px/1.45 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }}
    .log-task {{ color:#7cc7ff; font-weight:700; }}
    .log-ok {{ color:#67d58b; }}
    .log-changed {{ color:#ffd166; }}
    .log-warn {{ color:#ffb86b; font-weight:700; }}
    .log-error {{ color:#ff6b6b; font-weight:700; }}
    .log-skip {{ color:#8793a2; }}
    .log-command {{ color:#c792ea; }}
    @media (max-width: 980px) {{ main {{ grid-template-columns:1fr; }} .grid {{ grid-template-columns:1fr; }} }}
  </style>
</head>
<body>
  <header>
    <h1>Deploy INF</h1>
  </header>
  <main>
    <section>
      <form id="form">
        <label class="field">
          <span>ТЫ ОБНОВИЛ ISP? <button class="hint" type="button" data-tip="Перед запуском задания ISP должен быть обновлен. Если выбрать Нет, deploy_inf.sh остановится.">?</button></span>
          <select name="isp_updated">
            <option value="yes">Да</option>
            <option value="no" selected>Нет</option>
          </select>
        </label>
        <div class="grid">{''.join(main_fields)}</div>
        <label class="switch">
          <input id="ipsChanged" name="ips_changed" type="checkbox">
          IP адреса поменялись
        </label>
        <div id="ipBox" class="grid">{''.join(ip_fields)}</div>
        <label class="switch confirm">
          <input id="confirmRun" type="checkbox">
          Я проверил ответы и понимаю, что сейчас запустится deploy. Боже, благослови Америку!
        </label>
        <div class="actions">
          <button id="runBtn" class="primary" type="submit" disabled>Подтвердить и запустить</button>
          <span id="status">Готов к запуску</span>
        </div>
      </form>
    </section>
    <section>
      <pre id="log">Здесь появится вывод deploy_inf.sh и Ansible.</pre>
    </section>
  </main>
  <script>
    const form = document.getElementById('form');
    const runBtn = document.getElementById('runBtn');
    const statusEl = document.getElementById('status');
    const logEl = document.getElementById('log');
    const ipsChanged = document.getElementById('ipsChanged');
    const ipBox = document.getElementById('ipBox');
    const confirmRun = document.getElementById('confirmRun');
    let pos = 0;
    let timer = null;

    function escapeHtml(text) {{
      return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    }}

    function classForLine(line) {{
      const plain = line.replace(/\\x1b\\[[0-9;]*m/g, '');
      if (/FAILED|ERROR|UNREACHABLE|fatal:|ОШИБКА/i.test(plain)) return 'log-error';
      if (/WARNING|WARN|ВНИМАНИЕ/i.test(plain)) return 'log-warn';
      if (/^TASK \\[|^PLAY \\[|^PLAY RECAP|^RUNNING HANDLER/i.test(plain)) return 'log-task';
      if (/^\\$ /.test(plain)) return 'log-command';
      if (/changed:|changed=/i.test(plain)) return 'log-changed';
      if (/ok:|ok=/i.test(plain)) return 'log-ok';
      if (/skipping:|skipped=/i.test(plain)) return 'log-skip';
      return '';
    }}

    function appendColoredLog(chunk) {{
      const parts = chunk.split(/(\\n)/);
      for (let i = 0; i < parts.length; i += 1) {{
        const part = parts[i];
        if (part === '\\n') {{
          logEl.insertAdjacentHTML('beforeend', '\\n');
          continue;
        }}
        if (!part) continue;
        const cls = classForLine(part);
        const safe = escapeHtml(part.replace(/\\x1b\\[[0-9;]*m/g, ''));
        logEl.insertAdjacentHTML('beforeend', cls ? `<span class="${{cls}}">${{safe}}</span>` : safe);
      }}
      logEl.scrollTop = logEl.scrollHeight;
    }}

    ipsChanged.addEventListener('change', () => {{
      ipBox.style.display = ipsChanged.checked ? 'grid' : 'none';
    }});

    confirmRun.addEventListener('change', () => {{
      runBtn.disabled = !confirmRun.checked;
    }});

    async function poll() {{
      const res = await fetch('/log?pos=' + pos);
      const data = await res.json();
      pos = data.pos;
      if (data.chunk) {{
        appendColoredLog(data.chunk);
      }}
      statusEl.textContent = data.running ? 'Выполняется...' : (data.exit_code === null ? 'Готов к запуску' : 'Завершено: ' + data.exit_code);
      runBtn.disabled = data.running || !confirmRun.checked;
      if (!data.running && timer) {{
        clearInterval(timer);
        timer = null;
      }}
    }}

    form.addEventListener('submit', async (event) => {{
      event.preventDefault();
      const payload = Object.fromEntries(new FormData(form).entries());
      payload.ips_changed = ipsChanged.checked;
      logEl.textContent = '';
      pos = 0;
      const res = await fetch('/run', {{
        method: 'POST',
        headers: {{'Content-Type':'application/json'}},
        body: JSON.stringify(payload)
      }});
      if (!res.ok) {{
        appendColoredLog(await res.text());
        return;
      }}
      runBtn.disabled = true;
      statusEl.textContent = 'Выполняется...';
      timer = setInterval(poll, 700);
      poll();
    }});
  </script>
</body>
</html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def send_text(self, body: str, status: int = 200, content_type: str = "text/html; charset=utf-8") -> None:
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/":
            self.send_text(page())
            return
        if parsed.path == "/log":
            try:
                pos = int(parsed.query.split("pos=", 1)[1]) if "pos=" in parsed.query else 0
            except ValueError:
                pos = 0
            with lock:
                chunk = "".join(state["log"][pos:])
                payload = {
                    "chunk": chunk,
                    "pos": len(state["log"]),
                    "running": state["running"],
                    "exit_code": state["exit_code"],
                }
            self.send_text(json.dumps(payload, ensure_ascii=False), content_type="application/json; charset=utf-8")
            return
        self.send_text("Not found", 404, "text/plain; charset=utf-8")

    def do_POST(self):
        if urlparse(self.path).path != "/run":
            self.send_text("Not found", 404, "text/plain; charset=utf-8")
            return
        length = int(self.headers.get("Content-Length", "0"))
        try:
            data = json.loads(self.rfile.read(length).decode("utf-8"))
        except json.JSONDecodeError:
            self.send_text("Некорректный JSON", 400, "text/plain; charset=utf-8")
            return
        with lock:
            if state["running"]:
                self.send_text("Запуск уже идет", 409, "text/plain; charset=utf-8")
                return
            state["running"] = True
            state["exit_code"] = None
            state["started_at"] = time.time()
            state["log"] = []
        thread = threading.Thread(target=run_deploy, args=(data,), daemon=True)
        thread.start()
        self.send_text(json.dumps({"ok": True}), content_type="application/json; charset=utf-8")


def main() -> int:
    if not DEPLOY_SCRIPT.exists():
        print(f"Не найден {DEPLOY_SCRIPT}", file=sys.stderr)
        return 1
    port = choose_port(int(os.environ.get("DEPLOY_WEB_PORT", DEFAULT_PORT)))
    server = ThreadingHTTPServer(("", port), Handler)
    ip = local_ip()
    print(f"Ты запустил конфигуратор 2 модуля. Открой БРАУЗЕР НА HQ-CLI и введи адрес Веб-интерфейса.")
    print(f"Веб-интерфейс запущен: http://{ip}:{port}")
    print(f"Локально: http://127.0.0.1:{port}")
    print("Открой адрес, заполни форму и нажми 'Подтвердить и запустить'.")
    print("ЗАПУСКАТЬ ТОЛЬКО НА BR-SRV!")
    print("Для выхода нажми Ctrl+C'.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nОстановка веб-интерфейса.")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
