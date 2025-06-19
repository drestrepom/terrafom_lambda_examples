// En tu fichero index.js (o el handler de tu Lambda)
import { SecretsManagerClient, GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";

// Cache para el secreto, para no tener que pedirlo en cada invocación
let cachedSecret;

async function getSecret() {
    if (cachedSecret) {
        return cachedSecret;
    }

    const secretArn = process.env.SECRET_ARN;
    if (!secretArn) {
        throw new Error("SECRET_ARN environment variable not set.");
    }

    const client = new SecretsManagerClient();
    const command = new GetSecretValueCommand({ SecretId: secretArn });

    try {
        const data = await client.send(command);
        if (data.SecretString) {
            cachedSecret = JSON.parse(data.SecretString);
            return cachedSecret;
        }
        // Para secretos binarios
        // const buff = Buffer.from(data.SecretBinary, 'base64');
        // cachedSecret = buff.toString('ascii');
    } catch (err) {
        console.error("Error retrieving secret:", err);
        throw err;
    }
}

export const handler = async (event) => {
    try {
        const secrets = await getSecret();
        const dbPassword = secrets.DATABASE_PASSWORD; // O la clave que hayas definido en el secreto

        // ... el resto de la lógica de tu función ...

        return {
            statusCode: 200,
            body: JSON.stringify(`Successfully used secret! ${dbPassword} from hello1`),
        };
    } catch (error) {
        return {
            statusCode: 500,
            body: JSON.stringify('Error processing request'),
        };
    }
};
