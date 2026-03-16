FROM ballerina/ballerina:2201.13.1
USER root
WORKDIR /app
COPY --chown=ballerina:ballerina . .
USER ballerina
EXPOSE 8002
CMD ["bal", "run"]
