# phtest multi version PHP test environment

Runs multiple PHP configuration side by side
in Docker. The legacy versions are compiled from source and served
over Apache (via `php-cgi` + `mod_cgid`); 7.4.33 and 8.5.6 use the official
`php:<version>-apache` images (`mod_php`, no custom build needed). Every
version has its own `disable_functions` list you can edit and reload
without rebuilding anything.

## Layout

```
docker/Dockerfile           # parameterized build recipe (PHP_SERIES, PHP_VERSION, CONFIGURE_FLAGS) — legacy versions only
docker/apache-php-cgi.conf  # Apache CGI wiring (mod_cgid + mod_actions) — legacy versions only
docker-compose.yml          # all 7 services (build args or image), ports, and volumes
conf/<version>/php.ini      # per-version config, bind-mounted — edit + restart to apply
www/                        # shared docroot, bind-mounted into every container
```

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

Repeat per version build args are in the table in `docker-compose.yml`.
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

Drop your `.php` file into `www/` it's bind-mounted read-write into every
container's docroot, so the same file is reachable on different environment setup

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
