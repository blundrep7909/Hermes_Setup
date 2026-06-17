FROM python:3.12-slim
RUN pip install --no-cache-dir hermes-agent[acp]
WORKDIR /opt/data
EXPOSE 8642
ENV API_SERVER_ENABLED=true
CMD ["hermes", "gateway", "run", "--replace"]