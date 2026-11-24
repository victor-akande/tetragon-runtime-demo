FROM python:3.12-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_ROOT_USER_ACTION=ignore \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/* \
 && pip install --no-cache-dir flask==3.1.*

WORKDIR /app
COPY app.py .

# Decoy credential used by the optional stateful "tripwire" act.
RUN mkdir -p /app/.aws \
 && printf '[default]\naws_access_key_id = AKIADECOYDECOYDECOY0\naws_secret_access_key = decoy-not-a-real-key\n' > /app/.aws/credentials

EXPOSE 5000
CMD ["python", "app.py"]
