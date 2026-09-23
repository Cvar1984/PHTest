# phtest — multi-version PHP test environment

Runs PHP 4.1.2, 4.2.3, 4.3.0, 4.3.11, 5.0.5, 7.4.33, and 8.5.6 side by side
in Docker. The five legacy versions are compiled from source and served
over Apache (via `php-cgi` + `mod_cgid`); 7.4.33 and 8.5.6 use the official
`php:<version>-apache` images (`mod_php`, no custom build needed). Every
version has its own `disable_functions` list you can edit and reload
without rebuilding anything.

## Ports

| Version | URL                    | php.ini                |
|---------|------------------------|-------------------------|
| 4.1.2   | http://localhost:8412  | `conf/4.1.2/php.ini`   |
| 4.2.3   | http://localhost:8423  | `conf/4.2.3/php.ini`   |
| 4.3.0   | http://localhost:8430  | `conf/4.3.0/php.ini`   |
| 4.3.11  | http://localhost:8431  | `conf/4.3.11/php.ini`  |
| 5.0.5   | http://localhost:8505  | `conf/5.0.5/php.ini`   |
| 7.4.33  | http://localhost:8743  | `conf/7.4.33/php.ini`  |
| 8.5.6   | http://localhost:8856  | `conf/8.5.6/php.ini`   |

## Starting the containers

With the `docker compose` plugin installed (`sudo dnf install docker-compose-plugin`):

```
docker compose up -d --build
```

Without it, build and run each one directly:

```
docker build -f docker/Dockerfile -t phtest-php:4.1.2 \
  --build-arg PHP_SERIES=4 --build-arg PHP_VERSION=4.1.2 \
  --build-arg CONFIGURE_FLAGS="--enable-cgi --without-mysql --without-zlib" \
  docker

docker run -d --name phtest-4.1.2 -p 8412:80 \
  -v "$(pwd)/www:/var/www/html" \
  -v "$(pwd)/conf/4.1.2/php.ini:/usr/local/lib/php.ini" \
  phtest-php:4.1.2
```

Repeat per version — build args are in the table in `docker-compose.yml`.
7.4.33 and 8.5.6 need no build, just a run (they pull the official image):

```
docker run -d --name phtest-7.4.33 -p 8743:80 \
  -v "$(pwd)/www:/var/www/html" \
  -v "$(pwd)/conf/7.4.33/php.ini:/usr/local/etc/php/php.ini" \
  php:7.4.33-apache

docker run -d --name phtest-8.5.6 -p 8856:80 \
  -v "$(pwd)/www:/var/www/html" \
  -v "$(pwd)/conf/8.5.6/php.ini:/usr/local/etc/php/php.ini" \
  php:8.5.6-apache
```

Already built once? Just start the stopped containers instead of rebuilding:

```
docker start phtest-4.1.2 phtest-4.2.3 phtest-4.3.0 phtest-4.3.11 phtest-5.0.5 phtest-7.4.33 phtest-8.5.6
```

## Testing a script

Drop your `.php` file into `www/` — it's bind-mounted read-write into every
container's docroot, so the same file is reachable on all five ports at once:

```
curl http://localhost:8412/yourscript.php   # 4.1.2
curl http://localhost:8505/yourscript.php   # 5.0.5
curl http://localhost:8743/yourscript.php   # 7.4.33
curl http://localhost:8856/yourscript.php   # 8.5.6
```

Or just open the URL in a browser.

## Disabling / enabling functions

Each version's `conf/<version>/php.ini` has its own `disable_functions` line.
All 6 versions currently ship a **"strict hosting" profile** — the kind of
lockdown real shared hosts (cPanel/CloudLinux-style) apply — covering:

- **shell execution**: `exec, shell_exec, system, passthru, popen,
  proc_open, proc_close, proc_get_status, proc_nice, proc_terminate`
- **process control**: `pcntl_exec, pcntl_fork, pcntl_signal, pcntl_wait,
  pcntl_waitpid, posix_kill, posix_mkfifo, posix_setuid, posix_setgid,
  posix_seteuid, posix_setegid, posix_setsid, posix_setpgid`
- **env/runtime tampering**: `putenv, dl, ini_alter, ini_restore`
- **filesystem escape**: `symlink, link`
- **remote download / reverse shells**: `fsockopen, pfsockopen,
  stream_socket_client, stream_socket_server, curl_exec, curl_multi_exec,
  curl_init` — plus `allow_url_fopen = Off` and `allow_url_include = Off`,
  which block `fopen()`/`file_get_contents()`/`file()`/`include()` from
  reaching `http(s)://` URLs (that's an ini setting, not a function, so
  `disable_functions` alone can't cover it)
- **apache escape**: `apache_child_terminate, apache_setenv`
- **recon/disclosure**: `show_source, highlight_file, posix_uname`
- **log tampering**: `syslog, openlog, closelog`

Plus `expose_php = Off` to drop the `X-Powered-By` header.

Full commented list is in each `conf/<version>/php.ini`. To test with a
function re-enabled (or a new one blocked):

1. Edit `conf/<version>/php.ini` — remove the function from the comma
   list to allow it, or add one to block it.
2. Restart that one container to reload php.ini:
   ```
   docker restart phtest-<version>
   # e.g. docker restart phtest-4.1.2
   ```
   (`docker compose restart php-<version>` if you're using compose.)
3. Re-run your test. php.ini is only read at process start, so a restart
   is required — editing the file alone does nothing until you restart.

Example — allow `system()` on 4.1.2, confirm it, then lock it back down:

```
sed -i 's/system,//' conf/4.1.2/php.ini
docker restart phtest-4.1.2
curl http://localhost:8412/yourscript.php   # system() now callable

sed -i 's/exec,/exec,system,/' conf/4.1.2/php.ini
docker restart phtest-4.1.2
```

Same workflow for 7.4.33 / 8.5.6 — edit `conf/<version>/php.ini` and
`docker restart phtest-<version>`.

**Behavior differs by PHP generation when you call a disabled function:**
on 4.1.2 through 7.4.33 it emits a warning and returns `null`/`false`
(execution continues); on 8.5.6 it throws an **uncaught fatal `Error`**
and execution stops right there, unless the script wraps the call in
try/catch. The switch happened in PHP 8 — a script that probes several
dangerous functions in sequence behaves very differently depending on
which generation it's running under.

## Layout

```
docker/Dockerfile           # parameterized build recipe (PHP_SERIES, PHP_VERSION, CONFIGURE_FLAGS) — legacy versions only
docker/apache-php-cgi.conf  # Apache CGI wiring (mod_cgid + mod_actions) — legacy versions only
docker-compose.yml          # all 7 services (build args or image), ports, and volumes
conf/<version>/php.ini      # per-version config, bind-mounted — edit + restart to apply
www/                        # shared docroot, bind-mounted into every container
```

Note the php.ini mount path differs by version: legacy builds use
`/usr/local/lib/php.ini`, the official images (7.4.33, 8.5.6) use
`/usr/local/etc/php/php.ini`.

## Notes / known limitations

These apply to the five legacy (compiled-from-source) versions only —
7.4.33 and 8.5.6 are stock official images with the full standard
extension set (cURL, OpenSSL, JSON, etc.), no limitations below apply to
them:

- **No SSL, no cURL.** These images don't build the OpenSSL or cURL
  extensions, so `https://` requests via `file_get_contents()`/`curl_*()`
  fail fast with a "wrapper not found" warning. Fine for testing local
  script logic; not fine for scripts that fetch remote URLs.
- **5.0.5 has no XML/DOM/SimpleXML/PEAR.** libxml2 on the build's Debian
  Jessie base is too new for that era's XML code (opaque struct changes) —
  disabled to get a clean build. Unrelated to `disable_functions`.
- **4.1.2 / 4.2.3 have no `token_get_all()`; none of the five have
  `json_encode()`/`json_decode()`.** `token_get_all()` was added in PHP
  4.3.0; JSON only became a core extension in PHP 5.2.0. If a script calls
  either, that's a script compatibility issue, not something
  `disable_functions` controls.
- **Always restart after editing php.ini.** Each container's PHP process
  only reads php.ini once, at spawn time.
