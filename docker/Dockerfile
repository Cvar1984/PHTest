FROM debian/eol:jessie

ARG PHP_SERIES
ARG PHP_VERSION
ARG CONFIGURE_FLAGS

RUN echo "deb http://archive.debian.org/debian jessie main" > /etc/apt/sources.list \
 && echo "deb http://archive.debian.org/debian-security jessie/updates main" >> /etc/apt/sources.list \
 && apt-get -o Acquire::Check-Valid-Until=false update && apt-get install -y --no-install-recommends \
    build-essential \
    apache2 \
    zlib1g-dev \
    flex \
    wget \
    ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src
RUN wget -q https://museum.php.net/php${PHP_SERIES}/php-${PHP_VERSION}.tar.gz \
 && tar xzf php-${PHP_VERSION}.tar.gz

WORKDIR /usr/src/php-${PHP_VERSION}
RUN CFLAGS="-std=gnu89 -fgnu89-inline -w" ./configure ${CONFIGURE_FLAGS} \
 && make -j"$(nproc)" \
 && (test -f sapi/cgi/php && cp sapi/cgi/php /usr/local/bin/php-cgi || cp php /usr/local/bin/php-cgi) \
 && chmod +x /usr/local/bin/php-cgi \
 && mkdir -p /usr/lib/cgi-bin \
 && cp /usr/local/bin/php-cgi /usr/lib/cgi-bin/php-cgi \
 && rm -rf /usr/src/php-${PHP_VERSION} /usr/src/php-${PHP_VERSION}.tar.gz

RUN a2enmod cgid actions >/dev/null

COPY apache-php-cgi.conf /etc/apache2/conf-enabled/php-cgi.conf

EXPOSE 80
CMD ["/bin/sh", "-c", "rm -f /var/run/apache2/apache2.pid /var/run/apache2/cgisock.*; exec apachectl -D FOREGROUND"]
