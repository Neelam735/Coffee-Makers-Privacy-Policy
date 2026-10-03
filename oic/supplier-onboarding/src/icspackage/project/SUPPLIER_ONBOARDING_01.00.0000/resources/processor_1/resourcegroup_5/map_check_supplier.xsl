<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="2.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:src="http://xmlns.example.com/oic/supplier-onboarding" xmlns:erp="http://xmlns.example.com/oic/erp/suppliers" exclude-result-prefixes="src erp">
   <xsl:param name="CheckExistingSupplier" select="()"/>
   <xsl:param name="CreateSupplier" select="()"/>
   <xsl:param name="DefaultProcurementBU" select="'US1 Business Unit'"/>
   <xsl:param name="FaultMessage" select="'Unexpected error while creating the supplier in Oracle ERP Cloud.'"/>
   <xsl:template match="/">
      <xsl:variable name="req" select="/src:SupplierOnboardingRequest"/>
      <!-- Query param q for GET /suppliers: exact match on supplier name OR taxpayer id -->
      <q><xsl:value-of select="concat('Supplier=''', replace($req/src:supplierName, '''', ''''''), ''' or TaxpayerId=''', $req/src:taxRegistrationNumber, '''')"/></q>
      <fields>SupplierId,SupplierNumber,Supplier</fields>
      <onlyData>true</onlyData>
   </xsl:template>
</xsl:stylesheet>
