FROM perl:5.22
MAINTAINER Kevin Eye <kevineye@gmail.com>

COPY . /app

RUN cd /app && curl -s -L https://cpanmin.us | perl - --notest --installdeps .

ENV CLOUD_STORAGE /var/lib/cloud

VOLUME /var/lib/cloud

EXPOSE 80

CMD [ "/app/server.pl", "daemon", "-l http://*:80" ]
