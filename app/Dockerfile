# ---------- Stage 1: build the WAR with Maven (Java 11) ----------
FROM maven:3.8-eclipse-temurin-11 AS build

# Pin the application source to an exact commit for reproducible builds
ARG VPROFILE_REF=c26d07794353bc31bc8cb7345a9e9ca7f3a8a723

RUN apt-get update \
 && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone https://github.com/hkhcoder/vprofile-project.git . \
 && git checkout "${VPROFILE_REF}"

# Replace the hardcoded credentials with placeholders.
# Spring resolves ${...} from environment variables at runtime, and
# entrypoint.sh fills them from the Docker secret files.
RUN sed -i -E \
      -e 's|^(jdbc\.username)=.*|\1=${DB_USER}|' \
      -e 's|^(jdbc\.password)=.*|\1=${DB_PASSWORD}|' \
      -e 's|^(rabbitmq\.username)=.*|\1=${RABBITMQ_USER}|' \
      -e 's|^(rabbitmq\.password)=.*|\1=${RABBITMQ_PASSWORD}|' \
      src/main/resources/application.properties \
 && grep -E '^(jdbc\.(username|password)|rabbitmq\.(username|password))=' \
      src/main/resources/application.properties

RUN mvn package -DskipTests -B -ntp

# Explode the WAR now: the runtime filesystem is read-only,
# so Tomcat cannot unpack it at startup.
RUN mkdir /out && cd /out && jar xf /src/target/vprofile-v2.war

# ---------- Stage 2: runtime on Tomcat 9 (non-root) ----------
FROM tomcat:9.0-jdk11-temurin

RUN groupadd -g 10001 app \
 && useradd -u 10001 -g 10001 -M -s /usr/sbin/nologin app \
 && rm -rf /usr/local/tomcat/webapps/* \
 && (command -v curl >/dev/null \
     || (apt-get update \
         && apt-get install -y --no-install-recommends curl \
         && rm -rf /var/lib/apt/lists/*))

COPY --from=build --chown=10001:10001 /out /usr/local/tomcat/webapps/ROOT
COPY --chown=10001:10001 entrypoint.sh /entrypoint.sh

RUN chmod 555 /entrypoint.sh \
 && mkdir -p /usr/local/tomcat/conf/Catalina/localhost \
 && chown -R 10001:10001 /usr/local/tomcat/conf/Catalina

USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
