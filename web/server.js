const express = require('express');
const fs = require('fs');
const path = require('path');
const app = express();
const port = 3000;

app.use(express.static('.'));

app.get('/get-csv-list', (req, res) => {
    const directoryPath = __dirname;
    
    fs.readdir(directoryPath, (err, files) => {
        if (err) {
            return res.status(500).send('Unable to scan directory: ' + err);
        }
        
        // Filter file CSV
        const csvFiles = files.filter(file => path.extname(file).toLowerCase() === '.csv' && file.includes('report'));
        
        // Kirim daftar nama file CSV
        res.json({ csvList: csvFiles });
    });
});

app.listen(port, () => {
    console.log(`Server is running at http://localhost:${port}`);
});