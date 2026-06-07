FROM registry.access.redhat.com/ubi9/python-311:latest

COPY *.py /app/
COPY templates/ /app/templates/

WORKDIR /app

EXPOSE 8080 8443

CMD ["python", "/app/consumer.py"]
